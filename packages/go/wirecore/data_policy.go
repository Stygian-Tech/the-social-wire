package wirecore

import "time"

const (
	SignalRetention              = 7 * 24 * time.Hour
	AppliedInboxRetention        = 24 * time.Hour
	DeadLetterRetention          = 14 * 24 * time.Hour
	ItemRetention                = 30 * 24 * time.Hour
	ActiveActorRetention         = 30 * 24 * time.Hour
	FollowEdgeRetention          = 30 * 24 * time.Hour
	CommunityAssignmentRetention = 7 * 24 * time.Hour
	ClusteringCadence            = 6 * time.Hour
	MaximumActiveActors          = 250000
	MaximumFollowEdgesPerActor   = 200
	MinimumGlobalCandidates      = 50
	MinimumLocaleCandidates      = 50
	DiverseFirstPageCount        = 50
)
