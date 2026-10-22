// bhp-release: makes, signs and checks BHPanel release manifests (ed25519).
//
//	bhp-release keygen                     prints "<private seed> <public key>", base64
//	bhp-release sign   <manifest> <sig>    signs with the seed in $BHP_RELEASE_KEY
//	bhp-release verify <manifest> <sig> <public key>
//
// The signature covers the manifest file's exact bytes and is written as one
// line of base64. bhpaneld checks it with the same public key built in.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
)

func die(f string, a ...interface{}) {
	fmt.Fprintf(os.Stderr, "bhp-release: "+f+"\n", a...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		die("usage: keygen | sign <manifest> <sig> | verify <manifest> <sig> <public key>")
	}
	switch os.Args[1] {
	case "keygen":
		seed := make([]byte, ed25519.SeedSize)
		if _, err := rand.Read(seed); err != nil {
			die("no randomness: %v", err)
		}
		pub := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
		fmt.Println(base64.StdEncoding.EncodeToString(seed), base64.StdEncoding.EncodeToString(pub))
	case "sign":
		if len(os.Args) != 4 {
			die("usage: sign <manifest> <sig>")
		}
		seed, err := base64.StdEncoding.DecodeString(strings.TrimSpace(os.Getenv("BHP_RELEASE_KEY")))
		if err != nil || len(seed) != ed25519.SeedSize {
			die("BHP_RELEASE_KEY is not a base64 ed25519 seed")
		}
		msg, err := os.ReadFile(os.Args[2])
		if err != nil {
			die("%v", err)
		}
		sig := ed25519.Sign(ed25519.NewKeyFromSeed(seed), msg)
		if err := os.WriteFile(os.Args[3], []byte(base64.StdEncoding.EncodeToString(sig)+"\n"), 0o644); err != nil {
			die("%v", err)
		}
		fmt.Println("public key:", base64.StdEncoding.EncodeToString(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)))
	case "verify":
		if len(os.Args) != 5 {
			die("usage: verify <manifest> <sig> <public key>")
		}
		msg, err := os.ReadFile(os.Args[2])
		if err != nil {
			die("%v", err)
		}
		s, err := os.ReadFile(os.Args[3])
		if err != nil {
			die("%v", err)
		}
		sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(s)))
		pub, perr := base64.StdEncoding.DecodeString(strings.TrimSpace(os.Args[4]))
		if err != nil || perr != nil || len(pub) != ed25519.PublicKeySize || !ed25519.Verify(pub, msg, sig) {
			die("BAD SIGNATURE")
		}
		fmt.Println("signature OK")
	default:
		die("unknown command %q", os.Args[1])
	}
}
