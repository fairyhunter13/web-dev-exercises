package awsstore

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/apigatewaymanagementapi"
	apitypes "github.com/aws/aws-sdk-go-v2/service/apigatewaymanagementapi/types"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/gateway"
)

// postAPI is the part of *apigatewaymanagementapi.Client that Poster actually
// calls. It exists so Post's GoneException translation can be tested without a
// live API Gateway. The real client already satisfies it.
type postAPI interface {
	PostToConnection(context.Context, *apigatewaymanagementapi.PostToConnectionInput, ...func(*apigatewaymanagementapi.Options)) (*apigatewaymanagementapi.PostToConnectionOutput, error)
}

// Poster sends frames back over a WebSocket connection through the
// @connections management API.
//
// The endpoint is per-request rather than the regional service endpoint: it is
// built from the domain name and stage in the event, which is why the client is
// constructed with BaseEndpoint by the caller.
type Poster struct {
	Client postAPI
}

// Post delivers one payload. A closed connection comes back as GoneException,
// which is translated to gateway.ErrGone so the routing layer can reap the row
// without importing an AWS type.
func (p Poster) Post(ctx context.Context, connID string, payload []byte) error {
	_, err := p.Client.PostToConnection(ctx, &apigatewaymanagementapi.PostToConnectionInput{
		ConnectionId: aws.String(connID),
		Data:         payload,
	})
	if err == nil {
		return nil
	}

	var gone *apitypes.GoneException
	if errors.As(err, &gone) {
		return gateway.ErrGone
	}
	return fmt.Errorf("post to connection: %w", err)
}

// NewPoster builds a management-API client pinned to one stage's callback URL.
func NewPoster(cfg aws.Config, domainName, stage string) Poster {
	endpoint := "https://" + domainName + "/" + stage
	return Poster{
		Client: apigatewaymanagementapi.NewFromConfig(cfg, func(o *apigatewaymanagementapi.Options) {
			o.BaseEndpoint = aws.String(endpoint)
		}),
	}
}
