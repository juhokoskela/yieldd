package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
)

func TestEBSSeedSelectionAndRetirement(t *testing.T) {
	var deleted []string
	created := 0
	var busy, empty bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		switch action := r.Form.Get("Action"); action {
		case "DescribeInstances":
			if !strings.Contains(r.Form.Encode(), "shutting-down") {
				t.Error("quota check omits draining instances")
			}
			fmt.Fprint(w, "<DescribeInstancesResponse><reservationSet>")
			if busy {
				fmt.Fprint(w, "<item><instancesSet><item><instanceId>i-other</instanceId></item></instancesSet></item>")
			}
			fmt.Fprint(w, "</reservationSet></DescribeInstancesResponse>")
		case "DescribeSnapshots":
			if r.Form.Get("Owner.1") != "self" {
				t.Error("snapshot owner missing")
			}
			for _, k := range []string{"YielddOwner", "YielddRepository", "YielddImage", "YielddLayout", "YielddWorkflow", "YielddJob"} {
				if !strings.Contains(r.Form.Encode(), k) {
					t.Error("missing lineage tag", k)
				}
			}
			fmt.Fprint(w, "<DescribeSnapshotsResponse><snapshotSet>")
			if !empty {
				for i, s := range []string{"completed", "error", "completed", "completed", "pending"} {
					fmt.Fprintf(w, "<item><snapshotId>snap-%d</snapshotId><startTime>2026-11-%02dT00:00:00Z</startTime><status>%s</status><encrypted>true</encrypted><volumeSize>12</volumeSize></item>", i, i+1, s)
				}
			}
			fmt.Fprint(w, "</snapshotSet></DescribeSnapshotsResponse>")
		case "CreateSnapshot":
			if r.Form.Get("VolumeId") != "vol-cache" || !strings.Contains(r.Form.Encode(), "YielddRun") {
				t.Error("incorrect snapshot source or provenance")
			}
			created++
			fmt.Fprint(w, "<CreateSnapshotResponse><snapshotId>snap-new</snapshotId><status>pending</status></CreateSnapshotResponse>")
		case "DeleteSnapshot":
			deleted = append(deleted, r.Form.Get("SnapshotId"))
			fmt.Fprint(w, "<DeleteSnapshotResponse><return>true</return></DeleteSnapshotResponse>")
		default:
			t.Errorf("unexpected EC2 action %s", action)
		}
	}))
	defer srv.Close()
	api := ec2.New(ec2.Options{BaseEndpoint: aws.String(srv.URL), Region: "eu-central-1", Credentials: aws.CredentialsProviderFunc(func(context.Context) (aws.Credentials, error) {
		return aws.Credentials{AccessKeyID: "local", SecretAccessKey: "local"}, nil
	})})
	f := awsFleet{api: api, cfg: exampleEC2(), owner: "test"}
	seed, err := f.seed(t.Context())
	if err != nil || seed != "snap-3" || strings.Join(deleted, ",") != "snap-1,snap-0" {
		t.Fatal("selection and retention", seed, deleted, err)
	}
	l := &lease{Name: fixtureRunner, EC2: &ec2Lease{Volume: "vol-cache", ProducerRun: 23}}
	if err := f.publish(t.Context(), l); err != nil || created != 0 {
		t.Fatal("published with a snapshot pending", err)
	}
	empty = true
	if seed, err := f.seed(t.Context()); err != nil || seed != "" {
		t.Fatal("cold start", seed, err)
	}
	if err := f.publish(t.Context(), l); err != nil || created != 1 {
		t.Fatal("failed to submit snapshot", err)
	}
	busy = true
	if _, err := f.seed(t.Context()); !retryableBootstrapVerification(err) {
		t.Fatal("occupied fleet", err)
	}
}
