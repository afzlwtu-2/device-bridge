package synccontrol

import (
	"bufio"
	"bytes"
	"context"
	"devicebridge/protocol"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"syscall"
	"time"
)

type workerIdentity struct {
	credential *syscall.Credential
	binary     string
}

// Network administration can remain privileged while file engines and imports
// run as the state owner. Android always stays in its existing app UID.
func stateWorker(state string) (*workerIdentity, error) {
	if runtime.GOOS != "linux" || os.Geteuid() != 0 {
		return nil, nil
	}
	info, err := os.Stat(state)
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid == 0 {
		return nil, nil
	}
	account, err := user.LookupId(strconv.FormatUint(uint64(stat.Uid), 10))
	if err != nil {
		return nil, errors.New("folder sync needs a normal Unix account for the state owner")
	}
	group, err := strconv.ParseUint(account.Gid, 10, 32)
	if err != nil {
		return nil, err
	}
	groups, err := account.GroupIds()
	if err != nil {
		return nil, err
	}
	credential := &syscall.Credential{Uid: stat.Uid, Gid: uint32(group)}
	for _, raw := range groups {
		id, e := strconv.ParseUint(raw, 10, 32)
		if e != nil {
			return nil, e
		}
		credential.Groups = append(credential.Groups, uint32(id))
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	binary := filepath.Join(filepath.Dir(executable), "bridge-cli")
	if info, err := os.Stat(binary); err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("update both DeviceBridge binaries to enable the unprivileged sync worker")
	}
	return &workerIdentity{credential: credential, binary: binary}, nil
}

type boundedError struct{ bytes.Buffer }

func (b *boundedError) Write(value []byte) (int, error) {
	n := len(value)
	if b.Len() < 4096 {
		left := 4096 - b.Len()
		if len(value) > left {
			value = value[:left]
		}
		_, _ = b.Buffer.Write(value)
	}
	return n, nil
}

func readWorkerLine(reader *bufio.Reader) (json.RawMessage, error) {
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return nil, errors.New("the sync worker did not return bounded control metadata")
	}
	if len(line) > 128<<10 || !json.Valid(line) {
		return nil, errors.New("invalid sync worker result")
	}
	return append(json.RawMessage{}, line...), nil
}

func (m *Manager) delegate(ctx context.Context, controller string, request protocol.SyncControl) (any, error) {
	if err := m.allowed(controller, request.Root, request.RemoteApproved); err != nil {
		return nil, err
	}
	if err := m.store.PreserveOwner(m.state); err != nil {
		return nil, err
	}
	if request.Operation != "start" {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		command, stderr, err := m.workerCommand(ctx, controller, request)
		if err != nil {
			return nil, err
		}
		stdout, err := command.StdoutPipe()
		if err != nil {
			return nil, err
		}
		if err = command.Start(); err != nil {
			return nil, err
		}
		result, readErr := readWorkerLine(bufio.NewReaderSize(stdout, 128<<10))
		if readErr != nil {
			_ = command.Process.Signal(syscall.SIGTERM)
		}
		waitErr := command.Wait()
		if waitErr != nil {
			return nil, errors.Join(waitErr, errors.New(stderr.String()))
		}
		return result, readErr
	}
	seconds := request.Seconds
	if seconds == 0 {
		seconds = 300
	}
	if seconds < 5 || seconds > 900 {
		return nil, errors.New("invalid sync session duration")
	}
	jobCtx, cancel := context.WithTimeout(m.ctx, time.Duration(seconds+30)*time.Second)
	type outcome struct {
		value any
		err   error
	}
	started := make(chan outcome, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		defer cancel()
		childRequest := request
		childRequest.OpenFirewall = false
		command, stderr, err := m.workerCommand(jobCtx, controller, childRequest)
		if err != nil {
			started <- outcome{err: err}
			return
		}
		stdout, err := command.StdoutPipe()
		if err != nil {
			started <- outcome{err: err}
			return
		}
		if err = command.Start(); err != nil {
			started <- outcome{err: err}
			return
		}
		reader := bufio.NewReaderSize(stdout, 128<<10)
		initial, err := readWorkerLine(reader)
		if err != nil {
			_ = command.Process.Signal(syscall.SIGTERM)
			_ = command.Wait()
			started <- outcome{err: errors.Join(err, errors.New(stderr.String()))}
			return
		}
		cleanup, err := openFirewall(jobCtx, request)
		if err != nil {
			_ = command.Process.Signal(syscall.SIGTERM)
			_ = command.Wait()
			started <- outcome{err: err}
			return
		}
		m.mu.Lock()
		m.workerActive[request.JobID] = true
		m.workerCancel[request.JobID] = cancel
		m.mu.Unlock()
		defer func() {
			m.mu.Lock()
			delete(m.workerActive, request.JobID)
			delete(m.workerCancel, request.JobID)
			m.mu.Unlock()
		}()
		started <- outcome{value: initial}
		_, readErr := readWorkerLine(reader)
		if readErr != nil {
			_ = command.Process.Signal(syscall.SIGTERM)
		}
		_ = command.Wait()
		if cleanup != nil {
			if err := cleanup(); err != nil {
				m.mu.Lock()
				m.workerCleanup[request.JobID] = err.Error()
				m.mu.Unlock()
			}
		}
	}()
	select {
	case result := <-started:
		return result.value, result.err
	case <-ctx.Done():
		cancel()
		return nil, ctx.Err()
	}
}

func (m *Manager) workerCommand(ctx context.Context, controller string, request protocol.SyncControl) (*exec.Cmd, *boundedError, error) {
	raw, err := json.Marshal(request)
	if err != nil {
		return nil, nil, err
	}
	command := exec.CommandContext(ctx, m.worker.binary, "--state", m.state, "sync-worker", controller, "-")
	command.Stdin = bytes.NewReader(raw)
	stderr := &boundedError{}
	command.Stderr = stderr
	command.SysProcAttr = &syscall.SysProcAttr{Credential: m.worker.credential, Pdeathsig: syscall.SIGTERM}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return command.Process.Signal(syscall.SIGTERM)
	}
	command.WaitDelay = 3 * time.Second
	return command, stderr, nil
}

var _ io.Writer = (*boundedError)(nil)
