package main

import (
	"bufio"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"time"
)

func executeScript() {
	lockFilePath := "/tmp/running"

	// Create a lock file to prevent multiple instances from running.
	file, err := os.OpenFile(lockFilePath, os.O_CREATE|os.O_EXCL, 0644)
	if err != nil {
		if os.IsExist(err) {
			fmt.Println("metrics.sh is already running.")
			return
		}
		fmt.Printf("Error creating lock file: %v\n", err)
		return
	}
	file.Close()

	defer func() {
		if err := os.Remove(lockFilePath); err != nil {
			fmt.Printf("Error removing lock file: %v\n", err)
		}
	}()

	// Execute the metrics.sh script.
	cmd := exec.Command("/bin/bash", "/usr/local/bin/metrics.sh")

	// Get pipes for stdout and stderr.
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Printf("Error getting stdout pipe: %v\n", err)
		return
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		fmt.Printf("Error getting stderr pipe: %v\n", err)
		return
	}

	// Start the command.
	if err := cmd.Start(); err != nil {
		fmt.Printf("Error starting metrics.sh: %v\n", err)
		return
	}

	// Stream the stdout and stderr output.
	go streamOutput(stdout, "STDOUT")
	go streamOutput(stderr, "STDERR")

	// Wait for the command to finish.
	if err := cmd.Wait(); err != nil {
		fmt.Printf("metrics.sh finished with error: %v\n", err)
	}
}

func streamOutput(pipe io.ReadCloser, source string) {
	scanner := bufio.NewScanner(pipe)
	for scanner.Scan() {
		line := scanner.Text()
		fmt.Printf("[%s] %s\n", source, line) // Log each line in real-time.
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("Error reading from %s: %v\n", source, err)
	}
}

func ensureLogFileExists() {
	filePath := "/tmp/metrics.log"
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		currentTime := time.Now().Unix()
		content := fmt.Sprintf("heart_beat %d\n", currentTime)
		err := os.WriteFile(filePath, []byte(content), 0644)
		if err != nil {
			fmt.Printf("Error creating %s: %v\n", filePath, err)
		}
	}
}

func main() {
	// Handler for the /metrics path
	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		ensureLogFileExists()

		// Read the contents of the metrics log file.
		contents, err := os.ReadFile("/tmp/metrics.log")
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprintf(w, "Error reading /tmp/metrics.log: %v", err)
			return
		}
		// Serve the contents of the metrics log file.
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, string(contents))

		// Attempt to execute the script asynchronously.
		go executeScript()
	})

	// Default handler for all other paths
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "OK")
	})

	fmt.Println("Server is listening on port 9199...")
	if err := http.ListenAndServe(":9199", nil); err != nil {
		fmt.Printf("Server failed to start: %v\n", err)
	}
}
