package awsstore

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/apigatewaymanagementapi"
	apitypes "github.com/aws/aws-sdk-go-v2/service/apigatewaymanagementapi/types"

	"github.com/fairyhunter13/web-dev-exercises/chat/backend/internal/gateway"
)

// TestNewPosterBuildsPerStageEndpoint locks in why NewPoster takes a domain
// name and stage instead of a fixed regional endpoint: the callback URL is
// per-deployment, so a reviewer changing this would break every WebSocket send.
func TestNewPosterBuildsPerStageEndpoint(t *testing.T) {
	p := NewPoster(aws.Config{}, "abc123.execute-api.us-east-1.amazonaws.com", "prod")

	client, ok := p.Client.(*apigatewaymanagementapi.Client)
	if !ok {
		t.Fatalf("Client is %T, want *apigatewaymanagementapi.Client", p.Client)
	}
	want := "https://abc123.execute-api.us-east-1.amazonaws.com/prod"
	if got := aws.ToString(client.Options().BaseEndpoint); got != want {
		t.Fatalf("BaseEndpoint = %q, want %q", got, want)
	}
}

// fakePostAPI is a hand-rolled postAPI so Post's error translation can be
// exercised without a live API Gateway management endpoint.
type fakePostAPI struct {
	err error
}

func (f *fakePostAPI) PostToConnection(_ context.Context, _ *apigatewaymanagementapi.PostToConnectionInput, _ ...func(*apigatewaymanagementapi.Options)) (*apigatewaymanagementapi.PostToConnectionOutput, error) {
	if f.err != nil {
		return nil, f.err
	}
	return &apigatewaymanagementapi.PostToConnectionOutput{}, nil
}

// TestPostTranslatesGoneExceptionToErrGone is the one test worth the whole
// step: the gateway package's own tests fake ErrGone directly, so nothing else
// proves the real client's GoneException is actually translated. If this
// translation broke, the symptom in production would be a slow leak of dead
// connection rows that never get reaped.
func TestPostTranslatesGoneExceptionToErrGone(t *testing.T) {
	p := Poster{Client: &fakePostAPI{err: &apitypes.GoneException{}}}

	err := p.Post(context.Background(), "c1", []byte(`{}`))

	if !errors.Is(err, gateway.ErrGone) {
		t.Fatalf("err = %v, want gateway.ErrGone", err)
	}
}

func TestPostPropagatesNonGoneFailure(t *testing.T) {
	want := errors.New("throttled")
	p := Poster{Client: &fakePostAPI{err: want}}

	err := p.Post(context.Background(), "c1", []byte(`{}`))

	if !errors.Is(err, want) {
		t.Fatalf("err = %v, want %v", err, want)
	}
	if errors.Is(err, gateway.ErrGone) {
		t.Fatal("a non-Gone failure must not be reported as ErrGone")
	}
}
