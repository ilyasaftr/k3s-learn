package authz

import (
	"strconv"
	"strings"
	"time"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	"github.com/ilyasaftr/coraza-envoy-ext-authz/internal/model"
)

func ParseCheckRequest(req *authv3.CheckRequest) model.Request {
	request := model.Request{
		ID:       strconv.FormatInt(time.Now().UnixNano(), 10),
		Method:   "GET",
		Path:     "/",
		Protocol: "HTTP/1.1",
		Mode:     model.ModeDetect,
	}

	if req == nil {
		return request
	}

	attrs := req.GetAttributes()
	request.Mode = normalizeMode(attrs.GetContextExtensions())

	httpReq := attrs.GetRequest().GetHttp()
	if httpReq == nil {
		return request
	}

	if id := strings.TrimSpace(httpReq.GetId()); id != "" {
		request.ID = id
	}
	if method := strings.TrimSpace(httpReq.GetMethod()); method != "" {
		request.Method = method
	}
	if proto := strings.TrimSpace(httpReq.GetProtocol()); proto != "" {
		request.Protocol = proto
	}

	request.Path, request.Query = splitPathAndQuery(httpReq.GetPath())
	request.Host = httpReq.GetHost()
	request.Headers = parseHeaders(httpReq)
	request.Body = requestBody(httpReq)

	request.ClientIP, request.ClientPort = peerAddress(attrs.GetSource())
	request.ServerIP, request.ServerPort = peerAddress(attrs.GetDestination())

	return request
}

func normalizeMode(contextExtensions map[string]string) model.Mode {
	for key, value := range contextExtensions {
		if strings.EqualFold(key, "mode") {
			mode := strings.ToLower(strings.TrimSpace(value))
			if mode == string(model.ModeBlock) {
				return model.ModeBlock
			}
			break
		}
	}
	return model.ModeDetect
}

func splitPathAndQuery(rawPath string) (string, string) {
	if rawPath == "" {
		return "/", ""
	}

	path := rawPath
	query := ""
	if idx := strings.Index(rawPath, "?"); idx >= 0 {
		path = rawPath[:idx]
		query = rawPath[idx+1:]
	}

	if path == "" {
		path = "/"
	}
	return path, query
}

func parseHeaders(httpReq *authv3.AttributeContext_HttpRequest) []model.Header {
	headers := make([]model.Header, 0, len(httpReq.GetHeaders()))

	for key, value := range httpReq.GetHeaders() {
		headers = append(headers, model.Header{
			Key:   strings.ToLower(key),
			Value: value,
		})
	}

	if headerMap := httpReq.GetHeaderMap(); headerMap != nil {
		for _, header := range headerMap.GetHeaders() {
			value := header.GetValue()
			if value == "" && len(header.GetRawValue()) > 0 {
				value = string(header.GetRawValue())
			}
			headers = append(headers, model.Header{
				Key:   strings.ToLower(header.GetKey()),
				Value: value,
			})
		}
	}

	return headers
}

func requestBody(httpReq *authv3.AttributeContext_HttpRequest) []byte {
	if len(httpReq.GetRawBody()) > 0 {
		return httpReq.GetRawBody()
	}
	if httpReq.GetBody() == "" {
		return nil
	}
	return []byte(httpReq.GetBody())
}

func peerAddress(peer *authv3.AttributeContext_Peer) (string, int) {
	if peer == nil || peer.GetAddress() == nil {
		return "", 0
	}

	socket := peer.GetAddress().GetSocketAddress()
	if socket == nil {
		return "", 0
	}

	port := 0
	switch value := socket.GetPortSpecifier().(type) {
	case *corev3.SocketAddress_PortValue:
		port = int(value.PortValue)
	}

	return socket.GetAddress(), port
}
