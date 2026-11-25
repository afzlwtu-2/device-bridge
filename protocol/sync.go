package protocol

const SyncControlFeature = "folder-sync-control-v1"

// SyncControl contains metadata only. File bytes flow between the two pinned
// sync engines; the requesting device never supplies a relay endpoint.
type SyncControl struct {
	Operation      string   `json:"operation"`
	Name           string   `json:"name,omitempty"`
	Root           string   `json:"root,omitempty"`
	Path           string   `json:"path,omitempty"`
	LocalPath      string   `json:"local_path,omitempty"`
	Group          string   `json:"group,omitempty"`
	PeerID         string   `json:"peer_id,omitempty"`
	PeerDeviceID   string   `json:"peer_device_id,omitempty"`
	Role           string   `json:"role,omitempty"`
	Mode           string   `json:"mode,omitempty"`
	Filter         string   `json:"filter,omitempty"`
	Excludes       []string `json:"excludes,omitempty"`
	JobID          string   `json:"job_id,omitempty"`
	Interface      string   `json:"interface,omitempty"`
	CIDR           string   `json:"cidr,omitempty"`
	Listen         string   `json:"listen,omitempty"`
	PeerEndpoint   string   `json:"peer_endpoint,omitempty"`
	Manifest       string   `json:"manifest_xxh64,omitempty"`
	Bytes          int64    `json:"bytes,omitempty"`
	Route          string   `json:"route,omitempty"`
	RemoteApproved bool     `json:"remote_approved,omitempty"`
	OpenFirewall   bool     `json:"open_firewall,omitempty"`
	Seconds        int      `json:"seconds,omitempty"`
}

type SyncNetwork struct {
	Interface string `json:"interface"`
	CIDR      string `json:"cidr"`
	Kind      string `json:"kind"`
}

type SyncLocation struct {
	Device    string `json:"device"`
	Name      string `json:"name"`
	Root      string `json:"root"`
	Path      string `json:"path"`
	LocalPath string `json:"local_path,omitempty"`
}

type SyncPair struct {
	Configured       bool         `json:"configured"`
	SourceRegistered bool         `json:"source_registered,omitempty"`
	TargetRegistered bool         `json:"target_registered,omitempty"`
	Group            string       `json:"group"`
	Source           SyncLocation `json:"source"`
	Target           SyncLocation `json:"target"`
	Mode             string       `json:"mode"`
	State            string       `json:"state"`
	Excludes         []string     `json:"excludes,omitempty"`
	SourceJob        string       `json:"source_job,omitempty"`
	TargetJob        string       `json:"target_job,omitempty"`
}
