.PHONY: sb test
sb:
	cd sb && go build -o ../bin/sb ./cmd/sb
test:
	cd sb && go vet ./... && go test ./...
