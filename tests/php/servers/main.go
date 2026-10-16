// servers: an SSH server and a Redis server on loopback, for tests/php.sh to
// run the ssh2 and redis extensions' test suites against, as this machine
// has neither.
//
//	servers -ssh 127.0.0.1:2222 -redis 127.0.0.1:6379 -user u -pass p -authorized key.pub
//
// SSH takes the user's password, or the public key in -authorized, and runs
// exec requests and shells with BusyBox's sh (-sh). Its SFTP subsystem is a
// filesystem in memory that has /tmp. Redis is miniredis. Both print a line
// when they listen, and run until the process ends.
package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

var (
	sshAddr    = flag.String("ssh", "", "address for the SSH server")
	redisAddr  = flag.String("redis", "", "address for the Redis server")
	user       = flag.String("user", "zigsaw", "the SSH user")
	pass       = flag.String("pass", "zigsaw", "the SSH user's password")
	authorized = flag.String("authorized", "", "a public key the SSH user may log in with")
	shell      = flag.String("sh", "busybox sh", "the shell that runs commands")
	verbose    = flag.Bool("v", false, "log SFTP requests")
)

func main() {
	flag.Parse()
	log.SetFlags(0)
	if *redisAddr != "" {
		r := miniredis.NewMiniRedis()
		if err := r.StartAddr(*redisAddr); err != nil {
			log.Fatalf("redis: %v", err)
		}
		fmt.Printf("redis listening on %s\n", r.Addr())
	}
	if *sshAddr != "" {
		if err := serveSSH(); err != nil {
			log.Fatalf("ssh: %v", err)
		}
	}
	select {}
}

func serveSSH() error {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		return err
	}
	var allowed ssh.PublicKey
	if *authorized != "" {
		b, err := os.ReadFile(*authorized)
		if err != nil {
			return err
		}
		if allowed, _, _, _, err = ssh.ParseAuthorizedKey(b); err != nil {
			return err
		}
	}
	config := &ssh.ServerConfig{
		PasswordCallback: func(c ssh.ConnMetadata, p []byte) (*ssh.Permissions, error) {
			if c.User() == *user && string(p) == *pass {
				return nil, nil
			}
			return nil, fmt.Errorf("wrong password for %s", c.User())
		},
		PublicKeyCallback: func(c ssh.ConnMetadata, k ssh.PublicKey) (*ssh.Permissions, error) {
			if c.User() == *user && allowed != nil && bytes.Equal(k.Marshal(), allowed.Marshal()) {
				return nil, nil
			}
			return nil, fmt.Errorf("unknown key for %s", c.User())
		},
	}
	config.AddHostKey(signer)
	l, err := net.Listen("tcp", *sshAddr)
	if err != nil {
		return err
	}
	// One filesystem for every session, as a real server's disk.
	files := cleaned(sftp.InMemHandler())
	if err := files.FileCmd.Filecmd(sftp.NewRequest("Mkdir", "/tmp")); err != nil {
		return err
	}
	fmt.Printf("ssh listening on %s\n", l.Addr())
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				log.Printf("ssh: %v", err)
				return
			}
			go serveConn(c, config, files)
		}
	}()
	return nil
}

func serveConn(c net.Conn, config *ssh.ServerConfig, files sftp.Handlers) {
	conn, chans, reqs, err := ssh.NewServerConn(c, config)
	if err != nil {
		return
	}
	defer conn.Close()
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		if nc.ChannelType() != "session" {
			nc.Reject(ssh.UnknownChannelType, "only sessions")
			continue
		}
		ch, requests, err := nc.Accept()
		if err != nil {
			continue
		}
		go serveSession(ch, requests, files)
	}
}

// A string as SSH encodes it in a request's payload: its length, then it.
func payloadString(b []byte) string {
	if len(b) < 4 {
		return ""
	}
	n := binary.BigEndian.Uint32(b)
	if int(n) > len(b)-4 {
		return ""
	}
	return string(b[4 : 4+n])
}

func serveSession(ch ssh.Channel, requests <-chan *ssh.Request, files sftp.Handlers) {
	var once sync.Once
	finish := func(code uint32) {
		once.Do(func() {
			ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Code uint32 }{code}))
			ch.Close()
		})
	}
	pty := false
	for req := range requests {
		switch req.Type {
		case "exec", "shell":
			req.Reply(true, nil)
			args := strings.Fields(*shell)
			if req.Type == "exec" {
				args = append(args, "-c", payloadString(req.Payload))
			} else if pty {
				// What a terminal shows: a login message, as OpenSSH's
				// message of the day, then prompts, as an interactive shell
				// prints them.
				io.WriteString(ch, "zigsaw's test server\r\nfor tests/php.sh\r\n")
				args = append(args, "-i")
			}
			go func() { finish(run(ch, args, pty)) }()
		case "subsystem":
			if payloadString(req.Payload) != "sftp" {
				req.Reply(false, nil)
				continue
			}
			req.Reply(true, nil)
			go func() {
				s := sftp.NewRequestServer(ch, files)
				s.Serve()
				s.Close()
				finish(0)
			}()
		case "pty-req":
			pty = true
			req.Reply(true, nil)
		case "env", "window-change":
			req.Reply(true, nil)
		default:
			// Signals among them: Windows has none to send.
			req.Reply(false, nil)
		}
	}
}

// Runs a command with the channel as its standard streams. With a pty, as
// a terminal would, its errors go with its output and what it's sent is
// echoed.
func run(ch ssh.Channel, args []string, pty bool) uint32 {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdout = ch
	cmd.Stderr = ch.Stderr()
	// A shell's first prompt comes before what's typed at it.
	ready := make(chan struct{})
	if pty {
		out := &firstWrite{w: ch, ready: ready}
		cmd.Stdout, cmd.Stderr = out, out
	} else {
		close(ready)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return 255
	}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(ch.Stderr(), "%v\n", err)
		return 127
	}
	go func() {
		var w io.Writer = stdin
		if pty {
			w = io.MultiWriter(ch, stdin)
			select {
			case <-ready:
			case <-time.After(2 * time.Second):
			}
		}
		io.Copy(w, ch)
		stdin.Close()
	}()
	if err := cmd.Wait(); err != nil {
		if e, ok := err.(*exec.ExitError); ok {
			return uint32(e.ExitCode())
		}
		return 255
	}
	return 0
}

// SFTP handlers that clean each request's paths, as a real server's
// filesystem reads "//tmp/x" as "/tmp/x" (ssh2's tests ask for such paths;
// the in-memory filesystem would keep them apart), and log each request
// with -v.
type cleanReader struct{ sftp.FileReader }
type cleanWriter struct{ sftp.FileWriter }
type cleanCmder struct{ sftp.FileCmder }
type cleanLister struct{ sftp.FileLister }

func clean(r *sftp.Request) *sftp.Request {
	r.Filepath = path.Clean(r.Filepath)
	if r.Target != "" {
		r.Target = path.Clean(r.Target)
	}
	return r
}

func logRequest(r *sftp.Request, err error) {
	if *verbose {
		log.Printf("sftp %s %q %q flags=%#x: %v", r.Method, r.Filepath, r.Target, r.Flags, err)
	}
}

func (h cleanReader) Fileread(r *sftp.Request) (io.ReaderAt, error) {
	x, err := h.FileReader.Fileread(clean(r))
	logRequest(r, err)
	return x, err
}

func (h cleanWriter) Filewrite(r *sftp.Request) (io.WriterAt, error) {
	x, err := h.FileWriter.Filewrite(clean(r))
	logRequest(r, err)
	return x, err
}

func (h cleanCmder) Filecmd(r *sftp.Request) error {
	err := h.FileCmder.Filecmd(clean(r))
	switch {
	case err == nil && r.Method == "Symlink":
		// pkg/sftp's Request: Filepath is the target, Target the link.
		links.Store(r.Target, r.Filepath)
	case err == nil && r.Method == "Remove":
		links.Delete(r.Filepath)
	}
	logRequest(r, err)
	return err
}

func (h cleanLister) Filelist(r *sftp.Request) (sftp.ListerAt, error) {
	clean(r)
	if r.Method == "Readlink" {
		if t, ok := links.Load(r.Filepath); ok {
			logRequest(r, nil)
			return listOf{linkTarget(t.(string))}, nil
		}
	}
	x, err := h.FileLister.Filelist(r)
	logRequest(r, err)
	return x, err
}

func cleaned(h sftp.Handlers) sftp.Handlers {
	return sftp.Handlers{FileGet: cleanReader{h.FileGet}, FilePut: cleanWriter{h.FilePut}, FileCmd: cleanCmder{h.FileCmd}, FileList: cleanLister{h.FileList}}
}

// A writer that closes ready at its first write.
type firstWrite struct {
	w     io.Writer
	ready chan struct{}
	once  sync.Once
}

func (f *firstWrite) Write(p []byte) (int, error) {
	f.once.Do(func() { close(f.ready) })
	return f.w.Write(p)
}

// The in-memory filesystem makes symlinks but can't read them back:
// the targets, by link.
var links sync.Map

// The answer to a Readlink request: one entry, named the target.
type linkTarget string

func (t linkTarget) Name() string       { return string(t) }
func (t linkTarget) Size() int64        { return 0 }
func (t linkTarget) Mode() os.FileMode  { return os.ModeSymlink | 0o777 }
func (t linkTarget) ModTime() time.Time { return time.Time{} }
func (t linkTarget) IsDir() bool        { return false }
func (t linkTarget) Sys() any           { return nil }

type listOf []os.FileInfo

func (l listOf) ListAt(ls []os.FileInfo, offset int64) (int, error) {
	if offset >= int64(len(l)) {
		return 0, io.EOF
	}
	n := copy(ls, l[offset:])
	if n < len(ls) {
		return n, io.EOF
	}
	return n, nil
}
