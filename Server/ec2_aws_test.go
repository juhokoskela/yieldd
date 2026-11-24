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

func testEC2Client(endpoint string) *ec2.Client {
	return ec2.New(ec2.Options{BaseEndpoint: aws.String(endpoint), Region: "eu-central-1", Credentials: aws.CredentialsProviderFunc(func(context.Context) (aws.Credentials, error) {
		return aws.Credentials{AccessKeyID: "local", SecretAccessKey: "local"}, nil
	})})
}

func TestEBSSeedSelectionAndRetirement(t *testing.T) {
	var deleted []string
	created := 0
	var busy, empty, denyDelete, pending bool
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
					if s == "pending" && !pending {
						continue
					}
					fmt.Fprintf(w, "<item><snapshotId>snap-%d</snapshotId><startTime>2000-11-%02dT00:00:00Z</startTime><status>%s</status><encrypted>true</encrypted><volumeSize>12</volumeSize></item>", i, i+1, s)
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
			if denyDelete {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			deleted = append(deleted, r.Form.Get("SnapshotId"))
			fmt.Fprint(w, "<DeleteSnapshotResponse><return>true</return></DeleteSnapshotResponse>")
		default:
			t.Errorf("unexpected EC2 action %s", action)
		}
	}))
	defer srv.Close()
	api := testEC2Client(srv.URL)
	f := awsFleet{api: api, cfg: exampleEC2(), owner: "test"}
	denyDelete = true
	seed, err := f.seed(t.Context())
	if err != nil || seed != "snap-3" || len(deleted) != 0 {
		t.Fatal("selection and retention", seed, deleted, err)
	}
	l := &lease{Name: fixtureRunner, EC2: &ec2Lease{Volume: "vol-cache", ProducerRun: 23}}
	pending = true
	if retire, due, err := f.planSnapshot(t.Context()); err != nil || due || len(retire) != 0 {
		t.Fatal("planned publication with a pending snapshot", retire, due, err)
	}
	pending = false
	retire, due, err := f.planSnapshot(t.Context())
	if err != nil || !due || strings.Join(retire, ",") != "snap-1,snap-0" {
		t.Fatal("incorrect retention plan", retire, due, err)
	}
	if err := f.publish(t.Context(), l, retire); err == nil || created != 0 {
		t.Fatal("ignored snapshot retention failure", err)
	}
	denyDelete = false
	if err := f.publish(t.Context(), l, retire); err != nil || created != 1 || strings.Join(deleted, ",") != "snap-1,snap-0" {
		t.Fatal("failed to submit snapshot", deleted, created, err)
	}
	empty = true
	if seed, err := f.seed(t.Context()); err != nil || seed != "" {
		t.Fatal("cold start", seed, err)
	}
	busy = true
	if _, err := f.seed(t.Context()); !retryableBootstrapVerification(err) {
		t.Fatal("occupied fleet", err)
	}
}

func TestEC2RetirementWaitsOnlyForActionableDisks(t *testing.T) {
	for _, tc := range []struct {
		states   []string
		retiring bool
		deletes  int
	}{
		{nil, true, 0},
		{[]string{"deleted", "deleting"}, true, 0},
		{[]string{"deleting", "in-use"}, false, 0},
		{[]string{"deleting", "available"}, false, 1},
		{[]string{"error"}, false, 0},
	} {
		t.Run(strings.Join(tc.states, "-"), func(t *testing.T) {
			deletes := 0
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.FormValue("Action") {
				case "DescribeVolumes":
					fmt.Fprint(w, "<DescribeVolumesResponse><volumeSet>")
					for i, s := range tc.states {
						fmt.Fprintf(w, "<item><volumeId>vol-%d</volumeId><status>%s</status></item>", i, s)
					}
					fmt.Fprint(w, "</volumeSet></DescribeVolumesResponse>")
				case "DeleteVolume":
					deletes++
					fmt.Fprint(w, "<DeleteVolumeResponse><return>true</return></DeleteVolumeResponse>")
				default:
					t.Error("unexpected EC2 action")
				}
			}))
			defer srv.Close()
			f := awsFleet{api: testEC2Client(srv.URL), cfg: exampleEC2(), owner: "canary"}
			got, err := f.disksRetiring(t.Context(), &lease{Name: fixtureRunner})
			if err != nil || got != tc.retiring || deletes != tc.deletes {
				t.Fatal(got, deletes, err)
			}
		})
	}
}
