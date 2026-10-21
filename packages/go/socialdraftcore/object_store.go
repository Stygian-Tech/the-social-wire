package socialdraftcore

import (
	"context"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"io"
)

// objectStore intentionally never handles plaintext or user-provided object keys.
type objectStore interface {
	Put(context.Context, string, io.ReadSeeker, int64) error
	Get(context.Context, string) (io.ReadCloser, error)
	Delete(context.Context, string) error
}
type s3Store struct {
	client *s3.Client
	bucket string
}

func newS3Store(c Config) objectStore {
	client := s3.New(s3.Options{Region: c.Region, BaseEndpoint: aws.String(c.Endpoint), UsePathStyle: true, RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired, ResponseChecksumValidation: aws.ResponseChecksumValidationWhenRequired, Credentials: credentials.NewStaticCredentialsProvider(c.AccessKeyID, c.SecretAccessKey, "")})
	return &s3Store{client: client, bucket: c.Bucket}
}
func (s *s3Store) Put(ctx context.Context, key string, r io.ReadSeeker, n int64) error {
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{Bucket: &s.bucket, Key: &key, Body: r, ContentLength: &n, ContentType: aws.String("application/octet-stream")})
	return err
}
func (s *s3Store) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	o, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &s.bucket, Key: &key})
	if err != nil {
		return nil, err
	}
	return o.Body, nil
}
func (s *s3Store) Delete(ctx context.Context, key string) error {
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &s.bucket, Key: &key})
	return err
}
