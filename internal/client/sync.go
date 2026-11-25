package client

import (
	"context"
	"devicebridge/protocol"
	"encoding/json"
	"io"
	"net/http"
	"time"
)

func (c *Client) SyncControl(ctx context.Context, request protocol.SyncControl) (json.RawMessage, error) {
	limit := 30 * time.Second
	if request.Operation == "status" || request.Operation == "stop" || request.Operation == "probe" || request.Operation == "info" {
		limit = 12 * time.Second
	}
	if request.Operation == "manifest" || request.Operation == "start" {
		limit = 3 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	response, err := c.request(ctx, http.MethodPost, "/v1/sync/control", nil, request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	var result json.RawMessage
	err = json.NewDecoder(io.LimitReader(response.Body, 128<<10)).Decode(&result)
	return result, err
}
