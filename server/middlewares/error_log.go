package middlewares

import (
	"bytes"
	"encoding/json"
	"fmt"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
)

func ErrorLogging() gin.HandlerFunc {
	return func(c *gin.Context) {
		w := &responseBodyWriter{body: &bytes.Buffer{}, ResponseWriter: c.Writer}
		c.Writer = w
		c.Next()
		var errorMsg string
		if w.body.Len() > 0 {
			var jsonBody struct {
				Code    int    `json:"code"`
				Message string `json:"message"`
			}
			if err := json.Unmarshal(w.body.Bytes(), &jsonBody); err == nil {
				if jsonBody.Code != 200 {
					errorMsg = fmt.Sprintf(" error: code=%d, message=%s", jsonBody.Code, jsonBody.Message)
				}
			}
		}
		if c.Writer.Status() >= 400 {
			if len(c.Errors) > 0 {
				errorMsg = c.Errors.String()
			} else if errorMsg == "" && w.body.Len() > 0 {
				body := w.body.String()
				if len(body) > 500 {
					errorMsg = body[:500] + "..."
				} else {
					errorMsg = body
				}
			}
		}

		if errorMsg != "" {
			log.Error(errorMsg)
		}
	}
}

type responseBodyWriter struct {
	gin.ResponseWriter
	body *bytes.Buffer
}

func (r *responseBodyWriter) Write(b []byte) (int, error) {
	r.body.Write(b)
	return r.ResponseWriter.Write(b)
}
