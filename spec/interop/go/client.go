package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

func runClient(target string) error {
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	stream, err := conn.NewStream(ctx, &grpc.StreamDesc{ClientStreams: true, ServerStreams: true}, "/test.GoServerFirst/Bidi")
	if err != nil {
		return err
	}
	first := new(wrapperspb.BytesValue)
	if err := stream.RecvMsg(first); err != nil {
		return fmt.Errorf("receiving server-first response: %w", err)
	}
	if !bytes.Equal(first.Value, []byte{42}) {
		return fmt.Errorf("unexpected first response: %v", first.Value)
	}
	if err := stream.SendMsg(wrapperspb.Bytes([]byte{7})); err != nil {
		return err
	}
	if err := stream.CloseSend(); err != nil {
		return err
	}
	second := new(wrapperspb.BytesValue)
	if err := stream.RecvMsg(second); err != nil || !bytes.Equal(second.Value, []byte{7}) {
		return fmt.Errorf("receiving echo: %v, %v", second.Value, err)
	}
	if err := stream.RecvMsg(new(wrapperspb.BytesValue)); err != io.EOF {
		return fmt.Errorf("expected stream EOF: %v", err)
	}

	if err := conn.Invoke(ctx, "/missing.Service/Echo", wrapperspb.Bytes(nil), new(wrapperspb.BytesValue)); status.Code(err) != codes.Unimplemented {
		return fmt.Errorf("expected unimplemented: %v", err)
	}
	response := new(wrapperspb.BytesValue)
	if err := conn.Invoke(ctx, "/test.GoServerFirst/Echo", wrapperspb.Bytes([]byte{9}), response); err != nil {
		return fmt.Errorf("reusing connection after rejection: %w", err)
	}
	if !bytes.Equal(response.Value, []byte{9}) {
		return fmt.Errorf("unexpected unary response: %v", response.Value)
	}
	fmt.Println("grpc-go client passed")
	return nil
}
