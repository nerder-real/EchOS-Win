//go:build windows

package main

import (
	"bytes"
	"encoding/binary"
	"strings"
	"time"
)

// sniffTCPInitial reads initial data from a TUN TCP connection,
// tries to sniff HTTP Host or TLS ClientHello SNI.
// Returns (initialData, sniffedDomain, sniffProtocol).
// The caller must write initialData to the outbound before continuing relay.
func sniffTCPInitial(conn interface {
	SetReadDeadline(time.Time) error
	Read([]byte) (int, error)
}) (initial []byte, domain string, proto string) {
	// Set a short read deadline for sniffing
	conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	defer conn.SetReadDeadline(time.Time{}) // clear deadline

	buf := make([]byte, 32768)
	var n int
	for {
		m, err := conn.Read(buf[n:])
		n += m
		if err != nil {
			break
		}
		// Try to sniff as soon as we have enough data
		if sniffTLS(buf[:n]) != "" || sniffHTTP(buf[:n]) != "" {
			break
		}
		if n >= len(buf) {
			break
		}
		if !shouldContinueSniffing(buf[:n]) {
			break
		}
	}
	if n <= 0 {
		return nil, "", ""
	}
	initial = make([]byte, n)
	copy(initial, buf[:n])

	// Try HTTP sniff first
	if d := sniffHTTP(initial); d != "" {
		return initial, d, "http"
	}

	// Try TLS SNI sniff
	if d := sniffTLS(initial); d != "" {
		return initial, d, "tls"
	}

	return initial, "", ""
}

// sniffHTTP extracts Host from HTTP/1.x request headers.
// Supports: GET/POST/HEAD/PUT/DELETE/OPTIONS/CONNECT
var httpMethods = []string{"GET", "POST", "HEAD", "PUT", "DELETE", "OPTIONS", "CONNECT", "PATCH"}

func sniffHTTP(data []byte) string {
	if !hasHTTPMethod(data) {
		return ""
	}

	// Find Host header
	lines := bytes.Split(data, []byte{'\n'})
	for _, line := range lines {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			break // end of headers
		}
		parts := bytes.SplitN(line, []byte{':'}, 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(strings.ToLower(string(parts[0])))
		if key == "host" {
			host := strings.TrimSpace(string(parts[1]))
			// Remove port if present
			if h, _, err := netSplitHostPort(host); err == nil {
				host = h
			}
			return strings.ToLower(host)
		}
	}
	return ""
}

func hasHTTPMethod(data []byte) bool {
	for _, m := range httpMethods {
		if len(data) <= len(m) {
			continue
		}
		if strings.EqualFold(string(data[:len(m)]), m) && (data[len(m)] == ' ' || data[len(m)] == '\t') {
			return true
		}
	}
	return false
}

func shouldContinueSniffing(data []byte) bool {
	const (
		minGenericSniffBytes = 1024
		maxHTTPSniffBytes    = 8 * 1024
		maxTLSSniffBytes     = 16*1024 + 5
	)

	if len(data) == 0 {
		return true
	}

	// TLS ClientHello may exceed 1024 bytes because of large extensions.
	// Once the first TLS record is complete and SNI is still absent, there is
	// little value in reading later records here; the caller will replay all
	// captured bytes to the outbound stream.
	if data[0] == 0x16 {
		if len(data) < 5 {
			return len(data) < minGenericSniffBytes
		}
		if data[1] == 3 {
			recordLen := int(binary.BigEndian.Uint16(data[3:5]))
			need := 5 + recordLen
			return len(data) < need && len(data) < maxTLSSniffBytes
		}
	}

	if hasHTTPMethod(data) {
		return !bytes.Contains(data, []byte("\r\n\r\n")) && len(data) < maxHTTPSniffBytes
	}

	return len(data) < minGenericSniffBytes
}

// netSplitHostPort splits host:port, handling IPv6 brackets
func netSplitHostPort(hostport string) (string, string, error) {
	// Handle [::1]:port
	if strings.HasPrefix(hostport, "[") {
		closeBracket := strings.Index(hostport, "]")
		if closeBracket < 0 {
			return hostport, "", nil
		}
		host := hostport[1:closeBracket]
		if closeBracket+1 < len(hostport) && hostport[closeBracket+1] == ':' {
			return host, hostport[closeBracket+2:], nil
		}
		return host, "", nil
	}
	parts := strings.SplitN(hostport, ":", 2)
	if len(parts) == 2 {
		return parts[0], parts[1], nil
	}
	return hostport, "", nil
}

// sniffTLS extracts SNI from TLS ClientHello.
// Reference: Xray-core common/protocol/tls/sniff.go ReadClientHello
func sniffTLS(data []byte) string {
	if len(data) < 5 {
		return ""
	}
	// TLS record: ContentType=0x16 (Handshake), Version, Length
	if data[0] != 0x16 {
		return ""
	}
	// Check TLS version major byte (3 = TLS 1.0/1.1/1.2/1.3)
	// data[1]=major, data[2]=minor
	if data[1] != 3 {
		return ""
	}

	recordLen := int(data[3])<<8 | int(data[4])
	if len(data) < 5+recordLen {
		// Not enough data for full record, try with what we have
		recordLen = len(data) - 5
	}

	handshake := data[5 : 5+recordLen]
	if len(handshake) < 4 {
		return ""
	}

	// Handshake: Type=0x01 (ClientHello), Length(3 bytes)
	if handshake[0] != 0x01 {
		return ""
	}

	// handshake length
	// hl := int(handshake[1])<<16 | int(handshake[2])<<8 | int(handshake[3])

	// ClientHello body starts at offset 4
	if len(handshake) < 38+4 {
		return ""
	}
	body := handshake[4:]

	// clientVersion(2) + random(32) = 34 bytes
	// Skip: version(2) + random(32)
	// body[0:2] = client version
	// body[2:34] = random
	sessionIDLen := int(body[34])
	if sessionIDLen > 32 || len(body) < 35+sessionIDLen {
		return ""
	}
	body = body[35+sessionIDLen:]

	// cipher suites
	if len(body) < 2 {
		return ""
	}
	cipherSuiteLen := int(body[0])<<8 | int(body[1])
	if cipherSuiteLen%2 == 1 || len(body) < 2+cipherSuiteLen {
		return ""
	}
	body = body[2+cipherSuiteLen:]

	// compression methods
	if len(body) < 1 {
		return ""
	}
	compressionLen := int(body[0])
	if len(body) < 1+compressionLen {
		return ""
	}
	body = body[1+compressionLen:]

	// extensions
	if len(body) < 2 {
		return ""
	}
	extensionsLength := int(body[0])<<8 | int(body[1])
	body = body[2:]
	if extensionsLength > len(body) {
		// Not all extensions data available, scan what we have
	}

	// Parse extensions looking for SNI (0x0000)
	for len(body) >= 4 {
		extension := binary.BigEndian.Uint16(body[0:2])
		length := int(binary.BigEndian.Uint16(body[2:4]))
		body = body[4:]

		if length > len(body) {
			// Truncated, but try to read what we can
			length = len(body)
		}

		if extension == 0x0000 { // server_name
			extData := body[:length]
			if len(extData) < 2 {
				break
			}
			// server_name_list_length
			// namesLen := int(extData[0])<<8 | int(extData[1])
			names := extData[2:]
			// Parse server name list
			for len(names) >= 3 {
				nameType := names[0]
				nameLen := int(names[1])<<8 | int(names[2])
				names = names[3:]
				if nameLen > len(names) {
					break
				}
				if nameType == 0 { // host_name
					sni := string(names[:nameLen])
					return strings.ToLower(sni)
				}
				names = names[nameLen:]
			}
			break
		}
		body = body[length:]
	}
	return ""
}
