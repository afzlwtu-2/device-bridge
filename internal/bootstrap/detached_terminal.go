package bootstrap

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const detachedHistoryBytes = 256 << 10

var terminalID = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,32}$`)

func matchesRestoredGroups(gid int, actual, expected []int) bool {
	actualNorm := slices.Clone(actual)
	slices.Sort(actualNorm)
	actualNorm = slices.Compact(actualNorm)
	expectedNorm := slices.Clone(expected)
	slices.Sort(expectedNorm)
	expectedNorm = slices.Compact(expectedNorm)
	if slices.Equal(actualNorm, expectedNorm) {
		return true
	}
	// Some su implementations (e.g. MagiskSU) include primary gid in supplementary groups.
	expectedWithGID := append(slices.Clone(expectedNorm), gid)
	slices.Sort(expectedWithGID)
	expectedWithGID = slices.Compact(expectedWithGID)
	return slices.Equal(actualNorm, expectedWithGID)
}

// Require the original app identity before running the launcher or serving
// any terminal input. Neither the supervisor nor the shell runs as root.
func CheckDetachedTerminalIdentity(uid, gid int, groups []int, contextLabel string) error {
	if uid < 10000 || os.Getuid() != uid || os.Geteuid() != uid || os.Getgid() != gid || os.Getegid() != gid {
		return errors.New("terminal launcher did not restore the Android app UID and GID")
	}
	actual, err := os.Getgroups()
	if err != nil || !matchesRestoredGroups(gid, actual, groups) {
		return errors.New("terminal launcher did not restore the Android app groups")
	}
	if contextLabel == "selinux-disabled" {
		if _, statErr := os.Stat("/sys/fs/selinux"); !errors.Is(statErr, os.ErrNotExist) {
			return errors.New("terminal launcher skipped SELinux context while SELinux is present")
		}
		if label, attrErr := os.ReadFile("/proc/self/attr/current"); attrErr == nil && strings.Trim(string(label), "\x00\r\n ") != "" {
			return errors.New("terminal launcher did not verify the Android app security context")
		}
	} else {
		label, err := os.ReadFile("/proc/self/attr/current")
		if err != nil || !strings.HasPrefix(contextLabel, "u:r:untrusted_app") ||
			strings.Trim(string(label), "\x00\r\n ") != contextLabel {
			return errors.New("terminal launcher did not restore the Android app security context")
		}
	}
	header := unix.CapUserHeader{Version: unix.LINUX_CAPABILITY_VERSION_3}
	var data [2]unix.CapUserData
	if err := unix.Capget(&header, &data[0]); err != nil {
		return err
	}
	for _, capabilities := range data {
		if capabilities.Effective != 0 || capabilities.Permitted != 0 || capabilities.Inheritable != 0 {
			return errors.New("terminal launcher retained capabilities")
		}
	}
	return nil
}

func LaunchDetachedTerminal(executable string, arguments []string) error {
	cmd := exec.Command(executable, arguments...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

type terminalAttachRequest struct {
	Version   int                  `json:"version"`
	Operation string               `json:"operation"`
	Request   LocalTerminalRequest `json:"request"`
}

type terminalReplay struct {
	mu      sync.Mutex
	frames  [][]byte
	bytes   int
	watcher chan []byte
}

func (r *terminalReplay) Write(p []byte) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	frame := slices.Clone(p)
	for r.bytes+len(frame) > detachedHistoryBytes && len(r.frames) > 0 {
		r.bytes -= len(r.frames[0])
		r.frames[0] = nil
		r.frames = r.frames[1:]
	}
	r.frames = append(r.frames, frame)
	r.bytes += len(frame)
	if r.watcher != nil {
		select {
		case r.watcher <- frame:
		default:
			close(r.watcher)
			r.watcher = nil
		}
	}
	return len(p), nil
}

func (r *terminalReplay) attach() ([][]byte, chan []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.watcher != nil {
		close(r.watcher)
	}
	r.watcher = make(chan []byte, 64)
	return slices.Clone(r.frames), r.watcher
}

func (r *terminalReplay) detach(watcher chan []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.watcher == watcher {
		close(watcher)
		r.watcher = nil
	}
}

// One app-owned socket and PTY per tab. The PTY consumes input and produces
// output independently of an Activity or a currently connected client.
func ServeDetachedTerminal(parent context.Context, stateDir, id string) error {
	if !terminalID.MatchString(id) {
		return errors.New("invalid terminal session ID")
	}
	dir := filepath.Join(stateDir, "pt")
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		return errors.New("terminal socket directory is unavailable or not private")
	}
	lock, err := os.OpenFile(filepath.Join(dir, id+".lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		return err
	}
	// Keep the lock file linked through the entire listener lifetime.
	defer os.Remove(lock.Name())
	path := filepath.Join(dir, id+".sock")
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	if err := os.Chmod(path, 0o600); err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	go func() { <-ctx.Done(); listener.Close() }()
	startup := time.AfterFunc(15*time.Second, cancel)
	defer startup.Stop()
	input, writer := io.Pipe()
	defer input.Close()
	defer writer.Close()
	replay := new(terminalReplay)
	var current *net.UnixConn
	var attached sync.Mutex
	var start sync.Once
	var completed sync.WaitGroup
	clients := make(chan struct{}, 8)
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			break
		}
		select {
		case clients <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		go func(conn *net.UnixConn) {
			defer func() { <-clients; conn.Close() }()
			fd, err := conn.SyscallConn()
			if err != nil {
				return
			}
			var peer *unix.Ucred
			if err := fd.Control(func(raw uintptr) { peer, _ = unix.GetsockoptUcred(int(raw), unix.SOL_SOCKET, unix.SO_PEERCRED) }); err != nil ||
				peer == nil || int(peer.Uid) != os.Getuid() {
				return
			}
			conn.SetDeadline(time.Now().Add(3 * time.Second))
			frames := bufio.NewScanner(conn)
			frames.Buffer(make([]byte, 4096), 64<<10)
			var request terminalAttachRequest
			if !frames.Scan() || json.Unmarshal(frames.Bytes(), &request) != nil || request.Version != 1 {
				return
			}
			switch request.Operation {
			case "status":
				fmt.Fprintln(conn, `{"version":1,"state":"available"}`)
				return
			case "stop":
				cancel()
				return
			case "attach":
			default:
				return
			}
			conn.SetDeadline(time.Time{})
			attached.Lock()
			if ctx.Err() != nil {
				attached.Unlock()
				return
			}
			if current != nil {
				current.Close()
			}
			current = conn
			history, updates := replay.attach()
			start.Do(func() {
				startup.Stop()
				completed.Add(1)
				go func() {
					defer completed.Done()
					defer cancel()
					scanner := bufio.NewScanner(input)
					scanner.Buffer(make([]byte, 4096), 64<<10)
					if err := RunLocalTerminal(ctx, stateDir, request.Request, scanner, replay); err != nil {
						_ = json.NewEncoder(replay).Encode(TerminalFrame{Data: []byte("\r\n" + err.Error() + "\r\n")})
					}
				}()
			})
			attached.Unlock()
			defer replay.detach(updates)
			go func() {
				defer conn.Close()
				for frames.Scan() {
					if _, err := writer.Write(append(frames.Bytes(), '\n')); err != nil {
						return
					}
				}
			}()
			// Keep the ready signal even when it has rotated out of replay.
			conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
			if len(history) > 0 {
				if _, err := io.WriteString(conn, "{\"state\":\"ready\"}\n"); err != nil {
					return
				}
			}
			for _, frame := range history {
				if _, err := conn.Write(frame); err != nil {
					return
				}
			}
			for {
				select {
				case <-ctx.Done():
					return
				case frame, ok := <-updates:
					if !ok {
						return
					}
					conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
					if _, err := conn.Write(frame); err != nil {
						return
					}
				}
			}
		}(conn)
	}
	cancel()
	attached.Lock()
	if current != nil {
		current.Close()
	}
	attached.Unlock()
	completed.Wait()
	return nil
}

func ParseTerminalGroups(value string) ([]int, error) {
	var groups []int
	for _, field := range strings.Fields(value) {
		group, err := strconv.Atoi(field)
		if err != nil || group < 0 {
			return nil, errors.New("invalid terminal group")
		}
		groups = append(groups, group)
	}
	return groups, nil
}
