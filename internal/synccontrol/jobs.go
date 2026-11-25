package synccontrol

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

type storedJob struct {
	Controller string `json:"controller"`
	Job        Job    `json:"job"`
	PID        int    `json:"pid"`
	Process    string `json:"process"`
	Worker     bool   `json:"worker"`
}

func processMark(pid int) string {
	if pid <= 0 {
		return ""
	}
	raw, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return ""
	}
	end := strings.LastIndexByte(string(raw), ')')
	if end < 0 {
		return ""
	}
	fields := strings.Fields(string(raw)[end+1:])
	if len(fields) < 20 {
		return ""
	}
	return fields[19]
}

func (m *Manager) jobPath(id string) (string, error) {
	if _, err := hex.DecodeString(id); err != nil || len(id) != 32 {
		return "", errors.New("invalid sync job identity")
	}
	return filepath.Join(m.state, "sync-control-v1", "jobs", id+".json"), nil
}

func (m *Manager) saveJob(job Job) error {
	name, err := m.jobPath(job.ID)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(name), 0700); err != nil {
		return err
	}
	raw, err := json.Marshal(storedJob{Controller: job.Controller, Job: job, PID: os.Getpid(), Process: processMark(os.Getpid()), Worker: m.WorkerProcess})
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(name), ".job-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err = file.Write(raw); err != nil {
		return err
	}
	if err = file.Sync(); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), name)
}

func (m *Manager) readJob(id string) (*Job, error) {
	name, err := m.jobPath(id)
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(name)
	if err != nil {
		return nil, err
	}
	var record storedJob
	if json.Unmarshal(raw, &record) != nil || record.Job.ID != id {
		return nil, errors.New("invalid saved sync job")
	}
	job := record.Job
	job.Controller = record.Controller
	if job.State == "running" && (record.Process == "" || processMark(record.PID) != record.Process) {
		job.State = "interrupted"
		job.Error = "The endpoint process restarted. Approve a new sync session to resume."
	}
	return &job, nil
}

func (m *Manager) stopSavedJob(id, controller string) error {
	name, err := m.jobPath(id)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(name)
	if err != nil {
		return err
	}
	var record storedJob
	if json.Unmarshal(raw, &record) != nil || record.Controller != controller {
		return errors.New("sync job owner mismatch")
	}
	if !record.Worker {
		return errors.New("the endpoint process still owns this job; stop it through that endpoint")
	}
	if record.Job.State != "running" || record.Process == "" || processMark(record.PID) != record.Process {
		return nil
	}
	info, err := os.Stat(filepath.Join("/proc", strconv.Itoa(record.PID)))
	if err != nil {
		return err
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); !ok || stat.Uid != uint32(os.Getuid()) {
		return errors.New("sync job process is outside this app's UID")
	}
	return syscall.Kill(record.PID, syscall.SIGTERM)
}
