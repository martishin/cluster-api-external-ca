package kmsservice

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/martishin/cluster-api-external-ca/internal/kmsserviceapi"
	"github.com/martishin/cluster-api-external-ca/internal/kmsservicegrpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

type Client struct {
	conn *grpc.ClientConn
}

type Config struct {
	Endpoint   string
	CACertPath string
	CertPath   string
	KeyPath    string
	ServerName string
}

func NewClient(cfg Config) (*Client, error) {
	endpoint := strings.TrimSpace(cfg.Endpoint)
	if endpoint == "" {
		return nil, fmt.Errorf("kmsservice endpoint cannot be empty")
	}
	tlsCfg, err := loadTLSConfig(cfg)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	conn, err := grpc.DialContext(ctx, endpoint,
		grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)),
		grpc.WithBlock(),
	)
	if err != nil {
		return nil, fmt.Errorf("dial kmsservice grpc endpoint %q: %w", endpoint, err)
	}
	return &Client{conn: conn}, nil
}

func (c *Client) Close() error {
	if c == nil || c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

func (c *Client) GetCA(ctx context.Context, caName string) ([]byte, error) {
	resp := &wrapperspb.StringValue{}
	err := c.conn.Invoke(ctx, kmsservicegrpc.GetCAMethod, wrapperspb.String(caName), resp)
	if err != nil {
		return nil, fmt.Errorf("kmsservice GetCA(%q) failed: %w", caName, err)
	}
	return []byte(resp.Value), nil
}

func (c *Client) SignCSR(ctx context.Context, caName string, csrPEM []byte) ([]byte, error) {
	payload, err := kmsservicegrpc.EncodeSignRequest(kmsserviceapi.SignCSRRequest{
		CAName: caName,
		CSRPEM: string(csrPEM),
	})
	if err != nil {
		return nil, err
	}
	resp := &wrapperspb.StringValue{}
	err = c.conn.Invoke(ctx, kmsservicegrpc.SignMethod, wrapperspb.String(payload), resp)
	if err != nil {
		return nil, fmt.Errorf("kmsservice SignCSR(%q) failed: %w", caName, err)
	}
	return []byte(resp.Value), nil
}

func loadTLSConfig(cfg Config) (*tls.Config, error) {
	caPath := strings.TrimSpace(cfg.CACertPath)
	certPath := strings.TrimSpace(cfg.CertPath)
	keyPath := strings.TrimSpace(cfg.KeyPath)
	if caPath == "" || certPath == "" || keyPath == "" {
		return nil, fmt.Errorf("kmsservice TLS inputs are required: ca-cert, client-cert, client-key")
	}
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		return nil, fmt.Errorf("read kmsservice ca cert %q: %w", caPath, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("parse kmsservice ca cert %q", caPath)
	}
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, fmt.Errorf("load kmsservice client keypair: %w", err)
	}
	tlsCfg := &tls.Config{
		RootCAs:      pool,
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	}
	if s := strings.TrimSpace(cfg.ServerName); s != "" {
		tlsCfg.ServerName = s
	}
	return tlsCfg, nil
}
