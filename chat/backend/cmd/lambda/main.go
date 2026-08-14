// Command lambda is the AWS build of the chat backend: one Go binary behind an
// API Gateway WebSocket API, handling $connect, $disconnect and sendmessage.
//
// It shares internal/chat (the wire protocol) and internal/gateway (the routing
// logic) with cmd/localserver, so the deployed app and the one a reviewer runs
// offline cannot drift apart.
//
// Built for provided.al2023 on arm64 with -tags lambda.norpc: the custom
// runtime is the only supported target for Go, arm64 is ~20% cheaper per
// GB-second, and norpc drops the unused net/rpc path from the binary.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/awsstore"
	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/gateway"
)

// Route keys, as API Gateway spells them. $connect and $disconnect are
// reserved; sendmessage is the custom route selected by the "type" field of the
// frame via the route selection expression $request.body.type.
const (
	routeConnect    = "$connect"
	routeDisconnect = "$disconnect"
)

func main() {
	// The SDK config and the DynamoDB client are built once, outside the
	// handler, so they are reused across warm invocations. Building them
	// per-request would add the credential lookup to every message.
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		slog.Error("load aws config", "err", err)
		os.Exit(1)
	}

	store := &awsstore.Dynamo{
		Client:          dynamodb.NewFromConfig(cfg),
		ConnectionTable: mustEnv("CONNECTIONS_TABLE"),
		MessageTable:    mustEnv("MESSAGES_TABLE"),
	}

	lambda.Start(func(ctx context.Context, req events.APIGatewayWebsocketProxyRequest) (events.APIGatewayProxyResponse, error) {
		return handle(ctx, cfg, store, req)
	})
}

// posterFor builds the Poster for one request. It is a package-level function
// field, rather than a direct call to awsstore.NewPoster, purely so a test can
// swap in a fake and exercise route dispatch without a live API Gateway.
var posterFor = func(cfg aws.Config, domainName, stage string) gateway.Poster {
	return awsstore.NewPoster(cfg, domainName, stage)
}

func handle(
	ctx context.Context,
	cfg aws.Config,
	store gateway.Store,
	req events.APIGatewayWebsocketProxyRequest,
) (events.APIGatewayProxyResponse, error) {
	rc := req.RequestContext

	// The management-API endpoint is per-stage and comes from the event, not
	// from configuration: hardcoding it would break the moment the API is
	// redeployed under a different id.
	router := &gateway.Router{
		Store:  store,
		Poster: posterFor(cfg, rc.DomainName, rc.Stage),
		NewID:  newID,
		NowMS:  func() int64 { return time.Now().UnixMilli() },
	}

	var err error
	switch rc.RouteKey {
	case routeConnect:
		err = router.Connect(ctx, rc.ConnectionID)
	case routeDisconnect:
		err = router.Disconnect(ctx, rc.ConnectionID)
	default:
		err = router.Message(ctx, rc.ConnectionID, []byte(req.Body))
	}

	if err != nil {
		// 500 on $connect refuses the handshake, which is right: a client that
		// could not be registered would never receive anything. On the other
		// routes the socket stays up and the client sees a dropped frame.
		slog.ErrorContext(ctx, "route failed",
			"route", rc.RouteKey, "conn", rc.ConnectionID, "err", err)
		return events.APIGatewayProxyResponse{StatusCode: 500, Body: "internal error"}, nil
	}
	return events.APIGatewayProxyResponse{StatusCode: 200, Body: "ok"}, nil
}

// newID returns a random message id. crypto/rand rather than math/rand because
// ids are echoed to every client, and a predictable sequence would let one
// client guess another's not-yet-delivered message id.
func newID() string {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand.Read on Linux cannot fail without the kernel CSPRNG being
		// broken; there is nothing sensible to fall back to.
		panic(errors.New("crypto/rand unavailable: " + err.Error()))
	}
	return hex.EncodeToString(b[:])
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		slog.Error("missing required environment variable", "key", key)
		os.Exit(1)
	}
	return v
}
