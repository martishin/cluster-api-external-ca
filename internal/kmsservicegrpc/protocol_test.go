package kmsservicegrpc

import (
	"testing"

	"github.com/martishin/cluster-api-external-ca/internal/kmsserviceapi"
)

func TestEncodeDecodeSignRequest_RoundTrip(t *testing.T) {
	in := kmsserviceapi.SignCSRRequest{
		CAName: "kubernetes-ca",
		CSRPEM: "-----BEGIN CERTIFICATE REQUEST-----\nabc\n-----END CERTIFICATE REQUEST-----",
	}
	payload, err := EncodeSignRequest(in)
	if err != nil {
		t.Fatalf("EncodeSignRequest failed: %v", err)
	}
	out, err := DecodeSignRequest(payload)
	if err != nil {
		t.Fatalf("DecodeSignRequest failed: %v", err)
	}
	if out.CAName != in.CAName || out.CSRPEM != in.CSRPEM {
		t.Fatalf("unexpected roundtrip output: got=%+v want=%+v", out, in)
	}
}

func TestDecodeSignRequest_InvalidPayload(t *testing.T) {
	if _, err := DecodeSignRequest("{not-json"); err == nil {
		t.Fatalf("expected error for invalid payload")
	}
}
