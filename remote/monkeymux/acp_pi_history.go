package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"
)

const (
	piAcpProviderID             = "builtin:pi-acp"
	piSessionMapMaxBytes        = 4 * 1024 * 1024
	piSessionLineMaxBytes       = 32 * 1024 * 1024
	piCompactionSummaryMaxBytes = 384 * 1024
	piSessionEntryMaxCount      = 1_000_000
)

var piSearchableSessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9-]{1,128}$`)

type piSessionMapFile struct {
	Sessions map[string]struct {
		SessionFile string `json:"sessionFile"`
	} `json:"sessions"`
}

type piSessionEntryMetadata struct {
	Type     string  `json:"type"`
	ID       string  `json:"id"`
	ParentID *string `json:"parentId"`
	Summary  string  `json:"summary"`
}

// piCompactionSummary recovers the context summary that pi-acp 0.0.33 drops
// when its session/load replay contains a compacted Pi conversation.
func (b *acpBridge) piCompactionSummary(raw json.RawMessage) json.RawMessage {
	if b.providerID != piAcpProviderID {
		return nil
	}
	method, sessionID := acpJSONRPCRequestSession(raw)
	if method != "session/load" || !validAcpSessionID(sessionID) {
		return nil
	}
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	notification, err := piCompactionSummaryNotification(homeDir, sessionID)
	if err != nil {
		return nil
	}
	return notification
}

func piCompactionSummaryNotification(homeDir, sessionID string) (json.RawMessage, error) {
	sessionFile, err := findPiSessionFile(homeDir, sessionID)
	if err != nil {
		return nil, err
	}
	summary, err := latestPiCompactionSummary(sessionFile)
	if err != nil || summary == "" {
		return nil, err
	}
	summary = truncateUTF8(summary, piCompactionSummaryMaxBytes)
	text := "Earlier Pi history was compacted. This is the context Pi retained:\n\n" + summary
	messageHash := sha256.Sum256([]byte(sessionID + "\x00" + summary))
	notification := map[string]any{
		"jsonrpc": "2.0",
		"method":  "session/update",
		"params": map[string]any{
			"sessionId": sessionID,
			"update": map[string]any{
				"sessionUpdate": "agent_message_chunk",
				"messageId":     "monkeymux-pi-compaction-" + hex.EncodeToString(messageHash[:8]),
				"content": map[string]any{
					"type": "text",
					"text": text,
				},
				"_meta": map[string]any{
					"monkeyMux": map[string]any{"piCompactionSummary": true},
				},
			},
		},
	}
	encoded, err := json.Marshal(notification)
	return json.RawMessage(encoded), err
}

func findPiSessionFile(homeDir, sessionID string) (string, error) {
	root, err := filepath.EvalSymlinks(filepath.Join(homeDir, ".pi", "agent", "sessions"))
	if err != nil {
		return "", err
	}
	mapPath := filepath.Join(homeDir, ".pi", "pi-acp", "session-map.json")
	if encoded, readErr := readBoundedFile(mapPath, piSessionMapMaxBytes); readErr == nil {
		var mapping piSessionMapFile
		if json.Unmarshal(encoded, &mapping) == nil {
			if candidate := mapping.Sessions[sessionID].SessionFile; candidate != "" {
				if safe, safeErr := safePiSessionFile(root, candidate, sessionID); safeErr == nil {
					return safe, nil
				}
			}
		}
	}
	if !piSearchableSessionIDPattern.MatchString(sessionID) {
		return "", errors.New("Pi session id cannot be searched safely")
	}
	pattern := filepath.Join(root, "*", "*_"+sessionID+".jsonl")
	candidates, err := filepath.Glob(pattern)
	if err != nil {
		return "", err
	}
	for _, candidate := range candidates {
		if safe, safeErr := safePiSessionFile(root, candidate, sessionID); safeErr == nil {
			return safe, nil
		}
	}
	return "", os.ErrNotExist
}

func safePiSessionFile(root, candidate, sessionID string) (string, error) {
	resolved, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(root, resolved)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) {
		return "", errors.New("Pi session file is outside the session store")
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() || filepath.Ext(resolved) != ".jsonl" {
		return "", errors.New("Pi session file is invalid")
	}
	file, err := os.Open(resolved)
	if err != nil {
		return "", err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	if !scanner.Scan() {
		return "", errors.New("Pi session header is unavailable")
	}
	var header struct {
		Type string `json:"type"`
		ID   string `json:"id"`
	}
	if json.Unmarshal(scanner.Bytes(), &header) != nil || header.Type != "session" || header.ID != sessionID {
		return "", errors.New("Pi session header does not match")
	}
	return resolved, nil
}

func latestPiCompactionSummary(sessionFile string) (string, error) {
	file, err := os.Open(sessionFile)
	if err != nil {
		return "", err
	}
	defer file.Close()
	parents := make(map[string]string)
	summaries := make(map[string]string)
	leafID := ""
	entryCount := 0
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), piSessionLineMaxBytes)
	for scanner.Scan() {
		var entry piSessionEntryMetadata
		if json.Unmarshal(scanner.Bytes(), &entry) != nil || entry.ID == "" || entry.Type == "session" {
			continue
		}
		entryCount++
		if entryCount > piSessionEntryMaxCount {
			return "", errors.New("Pi session has too many entries")
		}
		if entry.ParentID != nil {
			parents[entry.ID] = *entry.ParentID
		}
		if entry.Type == "compaction" && strings.TrimSpace(entry.Summary) != "" {
			summaries[entry.ID] = entry.Summary
		}
		leafID = entry.ID
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	visited := make(map[string]struct{})
	for leafID != "" {
		if _, exists := visited[leafID]; exists {
			return "", errors.New("Pi session parent cycle")
		}
		visited[leafID] = struct{}{}
		if summary := summaries[leafID]; summary != "" {
			return summary, nil
		}
		leafID = parents[leafID]
	}
	return "", nil
}

func readBoundedFile(path string, maxBytes int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() > maxBytes {
		return nil, errors.New("file exceeds safe read limit")
	}
	return io.ReadAll(io.LimitReader(file, maxBytes+1))
}

func truncateUTF8(value string, maxBytes int) string {
	value = strings.ToValidUTF8(value, "�")
	if len(value) <= maxBytes {
		return value
	}
	truncated := value[:maxBytes]
	for !utf8.ValidString(truncated) {
		truncated = truncated[:len(truncated)-1]
	}
	return strings.TrimSpace(truncated) + "…"
}
