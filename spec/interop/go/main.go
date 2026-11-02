// A reference server for the Crystal client, using grpc-go's transport and
// Protobuf implementation. Keep the service description in sync with peer.proto.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/encoding/gzip"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

type peerService interface{}

func unary(_ interface{}, ctx context.Context, decode func(interface{}) error, _ grpc.UnaryServerInterceptor) (interface{}, error) {
	request := new(wrapperspb.BytesValue)
	if err := decode(request); err != nil {
		return nil, err
	}
	method, _ := grpc.Method(ctx)
	switch method {
	case "/interop.Peer/Fail":
		return nil, status.Error(codes.ResourceExhausted, string(request.Value))
	case "/interop.Peer/Wait":
		<-ctx.Done()
		return nil, status.FromContextError(ctx.Err()).Err()
	}
	if err := grpc.SetSendCompressor(ctx, gzip.Name); err != nil {
		return nil, err
	}
	if err := grpc.SendHeader(ctx, metadata.Pairs("x-peer", "grpc-go")); err != nil {
		return nil, err
	}
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		grpc.SetTrailer(ctx, metadata.MD{"echo-bin": md.Get("echo-bin")})
	}
	return request, nil
}

func stream(_ interface{}, stream grpc.ServerStream) error {
	method, _ := grpc.MethodFromServerStream(stream)
	if err := stream.SendHeader(metadata.Pairs("x-peer", "grpc-go")); err != nil {
		return err
	}
	var joined []byte
	for {
		request := new(wrapperspb.BytesValue)
		err := stream.RecvMsg(request)
		if err == io.EOF {
			if method == "/interop.Peer/Upload" {
				return stream.SendMsg(wrapperspb.Bytes(joined))
			}
			return nil
		}
		if err != nil {
			return err
		}
		switch method {
		case "/interop.Peer/Upload":
			joined = append(joined, request.Value...)
		case "/interop.Peer/Watch":
			for i := 0; i < 16; i++ {
				if err := stream.SendMsg(request); err != nil {
					return err
				}
			}
			return nil
		default:
			if err := stream.SendMsg(request); err != nil {
				return err
			}
			if method == "/interop.Peer/Finish" {
				return nil // Finish while the client's request direction stays open.
			}
		}
	}
}

func main() {
	cert := flag.String("cert", "", "TLS certificate (empty for plaintext)")
	key := flag.String("key", "", "TLS private key")
	flag.Parse()
	options := []grpc.ServerOption{grpc.MaxConcurrentStreams(1)}
	if *cert != "" {
		creds, err := credentials.NewServerTLSFromFile(*cert, *key)
		if err != nil {
			log.Fatal(err)
		}
		options = append(options, grpc.Creds(creds))
	}
	server := grpc.NewServer(options...)
	server.RegisterService(&grpc.ServiceDesc{
		ServiceName: "interop.Peer",
		HandlerType: (*peerService)(nil),
		Methods: []grpc.MethodDesc{
			{MethodName: "Echo", Handler: unary},
			{MethodName: "Fail", Handler: unary},
			{MethodName: "Wait", Handler: unary},
		},
		Streams: []grpc.StreamDesc{
			{StreamName: "Watch", Handler: stream, ServerStreams: true},
			{StreamName: "Upload", Handler: stream, ClientStreams: true},
			{StreamName: "Chat", Handler: stream, ClientStreams: true, ServerStreams: true},
			{StreamName: "Finish", Handler: stream, ClientStreams: true, ServerStreams: true},
		},
	}, struct{}{})
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	// Readiness is announced after listen, without racing a reserved test port.
	fmt.Println(listener.Addr())
	if err := server.Serve(listener); err != nil {
		log.Fatal(err)
	}
}
