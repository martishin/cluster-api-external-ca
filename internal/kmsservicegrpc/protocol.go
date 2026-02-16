package kmsservicegrpc

import (
	"encoding/json"
	"fmt"

	"github.com/martishin/cluster-api-external-ca/internal/kmsserviceapi"
)

const (
	ServiceName = "kmsservice.v1.KMSService"
	GetCAMethod = "/" + ServiceName + "/GetCA"
	SignMethod  = "/" + ServiceName + "/SignCSR"
)

func EncodeSignRequest(req kmsserviceapi.SignCSRRequest) (string, error) {
	b, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("marshal sign request: %w", err)
	}
	return string(b), nil
}

func DecodeSignRequest(payload string) (*kmsserviceapi.SignCSRRequest, error) {
	var req kmsserviceapi.SignCSRRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return nil, fmt.Errorf("unmarshal sign request: %w", err)
	}
	return &req, nil
}
