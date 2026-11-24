package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/aws/retry"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go"
)

type awsFleet struct {
	api   *ec2.Client
	cfg   ec2Config
	owner string
	key   []byte
}

func newAWSFleet(ctx context.Context, c ec2Config, owner string, key []byte) (*awsFleet, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(c.Region))
	if err != nil {
		return nil, err
	}
	who, err := sts.NewFromConfig(cfg).GetCallerIdentity(ctx, &sts.GetCallerIdentityInput{})
	if err != nil {
		return nil, fmt.Errorf("verify AWS workload identity: %w", err)
	}
	if aws.ToString(who.Account) != c.Account {
		return nil, errors.New("EC2 credentials belong to a different AWS account")
	}
	return &awsFleet{ec2.NewFromConfig(cfg, ec2RequestLimits), c, owner, key}, nil
}

// The coordinator owns retries so the serialized queue does not sleep inside the SDK.
func ec2RequestLimits(o *ec2.Options) {
	o.RetryMaxAttempts = 1
	o.HTTPClient = &http.Client{Timeout: 15 * time.Second}
}

func tag(k, v string) types.Tag       { return types.Tag{Key: aws.String(k), Value: aws.String(v)} }
func filter(k, v string) types.Filter { return types.Filter{Name: aws.String(k), Values: []string{v}} }
func (f *awsFleet) lineage() []types.Tag {
	return []types.Tag{
		tag("YielddOwner", f.owner), tag("YielddRepository", f.cfg.Repository),
		tag("YielddImage", f.cfg.Image), tag("YielddLayout", "m9g-go-v1"),
		tag("YielddWorkflow", f.cfg.Workflow), tag("YielddJob", f.cfg.Job),
	}
}

func (f *awsFleet) snapshots(ctx context.Context) ([]types.Snapshot, error) {
	var filters []types.Filter
	for _, t := range f.lineage() {
		filters = append(filters, filter("tag:"+*t.Key, *t.Value))
	}
	pages := ec2.NewDescribeSnapshotsPaginator(f.api, &ec2.DescribeSnapshotsInput{OwnerIds: []string{"self"}, Filters: filters})
	var entries []types.Snapshot
	for pages.HasMorePages() {
		p, err := pages.NextPage(ctx)
		if err != nil {
			return nil, awsFailure("list cache snapshots", err)
		}
		entries = append(entries, p.Snapshots...)
	}
	slices.SortFunc(entries, func(a, b types.Snapshot) int { return aws.ToTime(b.StartTime).Compare(aws.ToTime(a.StartTime)) })
	return entries, nil
}

func (f *awsFleet) seed(ctx context.Context) (string, error) {
	// Check provider capacity as well as the local slot. A restored journal may
	// predate a launch, and shutting-down instances still consume the quota.
	pages := ec2.NewDescribeInstancesPaginator(f.api, &ec2.DescribeInstancesInput{Filters: []types.Filter{
		filter("tag:YielddRepository", f.cfg.Repository), filter("tag-key", "YielddOwner"),
		{Name: aws.String("instance-state-name"), Values: []string{"pending", "running", "stopping", "stopped", "shutting-down"}},
	}})
	for pages.HasMorePages() {
		busy, err := pages.NextPage(ctx)
		if err != nil {
			return "", awsFailure("check EC2 capacity", err)
		}
		for _, r := range busy.Reservations {
			if len(r.Instances) > 0 {
				return "", &temporaryStatusError{errors.New("EC2 repository slot is occupied; waiting for termination")}
			}
		}
	}
	entries, err := f.snapshots(ctx)
	if err != nil {
		return "", err
	}
	for _, s := range entries {
		if s.State == types.SnapshotStateCompleted {
			if !aws.ToBool(s.Encrypted) || aws.ToInt32(s.VolumeSize) != 12 {
				return "", errors.New("incompatible EBS cache snapshot in lineage")
			}
			return aws.ToString(s.SnapshotId), nil
		}
	}
	return "", nil
}

func (f *awsFleet) launchInput(l *lease) *ec2.RunInstancesInput {
	disk := &types.EbsBlockDevice{VolumeSize: aws.Int32(12), VolumeType: types.VolumeTypeGp3, DeleteOnTermination: aws.Bool(true), Encrypted: aws.Bool(true)}
	mode := "blank"
	if l.EC2.Seed != "" {
		disk.SnapshotId = aws.String(l.EC2.Seed)
		mode = "seeded"
	}
	// Keep this request stable across restart. An ambiguous reply reuses the same client token.
	data := fmt.Sprintf(`#!/bin/sh
set -eu
umask 077
cat >/run/yieldd-ec2-auth <<'HEADER'
Authorization: Bearer %s
HEADER
exec systemd-run --quiet --unit=yieldd-bootstrap /usr/local/sbin/yieldd-ec2-job '%s' '%s' '%s'
`, bootstrapToken(f.key, f.owner, l.Name), f.cfg.Endpoint, l.Name, mode)
	tags := append(f.lineage(), tag("YielddLease", l.Name))
	return &ec2.RunInstancesInput{
		ClientToken:                       aws.String(l.Name),
		ImageId:                           &f.cfg.Image,
		InstanceType:                      types.InstanceTypeM9gXlarge,
		SubnetId:                          &f.cfg.Subnet,
		SecurityGroupIds:                  []string{f.cfg.Group},
		MinCount:                          aws.Int32(1),
		MaxCount:                          aws.Int32(1),
		InstanceInitiatedShutdownBehavior: types.ShutdownBehaviorTerminate,
		UserData:                          aws.String(base64.StdEncoding.EncodeToString([]byte(data))),
		MetadataOptions: &types.InstanceMetadataOptionsRequest{
			HttpTokens:              types.HttpTokensStateRequired,
			HttpPutResponseHopLimit: aws.Int32(1),
		},
		BlockDeviceMappings: []types.BlockDeviceMapping{
			{DeviceName: aws.String("/dev/sdf"), Ebs: disk},
			{DeviceName: aws.String("/dev/sda1"), Ebs: &types.EbsBlockDevice{DeleteOnTermination: aws.Bool(true), Encrypted: aws.Bool(true)}},
		},
		TagSpecifications: []types.TagSpecification{
			{ResourceType: types.ResourceTypeInstance, Tags: tags},
			{ResourceType: types.ResourceTypeVolume, Tags: tags},
		},
	}
}

func (f *awsFleet) launch(ctx context.Context, l *lease) (ec2Host, error) {
	out, err := f.api.RunInstances(ctx, f.launchInput(l))
	if err != nil {
		return ec2Host{}, awsFailure("launch", err)
	}
	if len(out.Instances) != 1 {
		return ec2Host{}, errors.New("expected one EC2 instance")
	}
	return instanceHost(out.Instances[0]), nil
}

// AWS response messages may include submitted user data. Log only the error code.
func awsFailure(op string, err error) error {
	var api smithy.APIError
	if errors.As(err, &api) {
		safe := fmt.Errorf("EC2 %s: %s", op, api.ErrorCode())
		switch api.ErrorCode() {
		case "InsufficientInstanceCapacity", "VcpuLimitExceeded", "InstanceLimitExceeded", "ExpiredToken", "RequestExpired", "RequestLimitExceeded":
			return &temporaryStatusError{safe}
		}
		if retry.NewStandard().IsErrorRetryable(err) {
			return &temporaryStatusError{safe}
		}
		return safe
	}
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	return &temporaryStatusError{fmt.Errorf("EC2 %s request did not complete", op)}
}

func instanceHost(i types.Instance) ec2Host {
	h := ec2Host{id: aws.ToString(i.InstanceId)}
	if i.State != nil {
		h.state = string(i.State.Name)
	}
	for _, d := range i.BlockDeviceMappings {
		if aws.ToString(d.DeviceName) == "/dev/sdf" && d.Ebs != nil {
			h.volume = aws.ToString(d.Ebs.VolumeId)
		}
	}
	return h
}

func (f *awsFleet) host(ctx context.Context, l *lease) (ec2Host, error) {
	input := &ec2.DescribeInstancesInput{Filters: []types.Filter{filter("client-token", l.Name)}}
	if l.EC2.Instance != "" {
		input.InstanceIds = []string{l.EC2.Instance}
	}
	pages := ec2.NewDescribeInstancesPaginator(f.api, input)
	var h ec2Host
	for pages.HasMorePages() {
		out, err := pages.NextPage(ctx)
		if err != nil {
			var api smithy.APIError
			if l.EC2.Instance != "" && errors.As(err, &api) && api.ErrorCode() == "InvalidInstanceID.NotFound" {
				return ec2Host{}, nil
			}
			return ec2Host{}, awsFailure("observe instance", err)
		}
		for _, r := range out.Reservations {
			for _, i := range r.Instances {
				observed := instanceHost(i)
				if h.id != "" || observed.id == "" || (l.EC2.Instance != "" && observed.id != l.EC2.Instance) {
					return ec2Host{}, errors.New("EC2 lease identity mismatch")
				}
				owner := slices.IndexFunc(i.Tags, func(t types.Tag) bool { return aws.ToString(t.Key) == "YielddOwner" })
				if owner >= 0 {
					if aws.ToString(i.Tags[owner].Value) != f.owner {
						return ec2Host{}, errors.New("EC2 lease owner mismatch")
					}
				} else if observed.state != "terminated" || observed.id != l.EC2.Instance {
					// EC2 can remove tags from a terminated instance before it
					// disappears from the client-token lookup.
					return ec2Host{}, errors.New("EC2 lease owner missing")
				}
				h = observed
			}
		}
	}
	return h, nil
}

func (f *awsFleet) terminate(ctx context.Context, id string) error {
	_, err := f.api.TerminateInstances(ctx, &ec2.TerminateInstancesInput{InstanceIds: []string{id}})
	if err != nil {
		return awsFailure("terminate instance", err)
	}
	return nil
}

// A terminated instance consumes no slot once EBS owns deletion of every disk.
// EBS can report deleting for minutes after completing the cache snapshot.
func (f *awsFleet) disksRetiring(ctx context.Context, l *lease) (bool, error) {
	pages := ec2.NewDescribeVolumesPaginator(f.api, &ec2.DescribeVolumesInput{Filters: []types.Filter{
		filter("tag:YielddOwner", f.owner), filter("tag:YielddLease", l.Name), filter("tag:YielddRepository", f.cfg.Repository),
	}})
	retiring := true
	for pages.HasMorePages() {
		p, err := pages.NextPage(ctx)
		if err != nil {
			return false, awsFailure("check runner disks", err)
		}
		for _, v := range p.Volumes {
			if v.State == types.VolumeStateDeleting || v.State == types.VolumeStateDeleted {
				continue
			}
			retiring = false
			if v.State == types.VolumeStateAvailable && len(v.Attachments) == 0 {
				_, err := f.api.DeleteVolume(ctx, &ec2.DeleteVolumeInput{VolumeId: v.VolumeId})
				if err != nil {
					var api smithy.APIError
					if !errors.As(err, &api) || api.ErrorCode() != "InvalidVolume.NotFound" {
						return false, awsFailure("delete detached runner disk", err)
					}
				}
			}
		}
	}
	return retiring, nil
}

func (f *awsFleet) planSnapshot(ctx context.Context) (retire []string, due bool, err error) {
	entries, err := f.snapshots(ctx)
	if err != nil {
		return nil, false, err
	}
	kept := 0
	for _, s := range entries {
		switch s.State {
		case types.SnapshotStatePending:
			return nil, false, nil
		case types.SnapshotStateCompleted:
			if time.Since(aws.ToTime(s.StartTime)) < 24*time.Hour {
				return nil, false, nil
			}
			if kept < 2 {
				kept++
				continue
			}
		case types.SnapshotStateError:
		default:
			continue
		}
		retire = append(retire, aws.ToString(s.SnapshotId))
	}
	return retire, true, nil
}

func (f *awsFleet) prune(ctx context.Context, retire []string) error {
	for _, id := range retire {
		if _, err := f.api.DeleteSnapshot(ctx, &ec2.DeleteSnapshotInput{SnapshotId: aws.String(id)}); err != nil {
			return awsFailure("expire cache snapshot", err)
		}
	}
	return nil
}

func (f *awsFleet) publish(ctx context.Context, l *lease) error {
	tags := append(f.lineage(), tag("YielddLease", l.Name), tag("YielddRun", fmt.Sprint(l.EC2.ProducerRun)))
	snapshot, err := f.api.CreateSnapshot(ctx, &ec2.CreateSnapshotInput{VolumeId: &l.EC2.Volume, Description: aws.String("yieldd build cache"), TagSpecifications: []types.TagSpecification{{ResourceType: types.ResourceTypeSnapshot, Tags: tags}}})
	if err != nil {
		return awsFailure("create cache snapshot", err)
	}
	slog.Info("EC2 cache snapshot requested", "repository", f.cfg.Repository, "platform", "linux", "runner", l.Name, "run", l.EC2.ProducerRun, "snapshot", aws.ToString(snapshot.SnapshotId))
	return nil
}
