package main

import (
	"errors"
	"log"
	"math/rand"
	"os"
	"time"

	"github.com/couchbase/gocb/v2"
	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
)

var collection *gocb.Collection

func main() {
	cbNodes := getEnv("CB_NODES", "10.129.7.234")
	cbUser := getEnv("CB_USER", "Administrator")
	cbPass := getEnv("CB_PASS", "Password123!")
	cbBucket := getEnv("CB_BUCKET", "bench-bucket")
	port := getEnv("PORT", "8080")

	// 1. Connect to Couchbase Cluster
	log.Printf("Connecting to Couchbase nodes: %s...", cbNodes)
	opts := gocb.ClusterOptions{
		Authenticator: gocb.PasswordAuthenticator{
			Username: cbUser,
			Password: cbPass,
		},
		TimeoutsConfig: gocb.TimeoutsConfig{
			KVTimeout: 2500 * time.Millisecond,
		},
	}

	cluster, err := gocb.Connect("couchbase://"+cbNodes, opts)
	if err != nil {
		log.Fatalf("Failed to connect to Couchbase: %v", err)
	}

	bucket := cluster.Bucket(cbBucket)
	err = bucket.WaitUntilReady(30*time.Second, nil)
	if err != nil {
		log.Fatalf("Bucket ready timeout: %v", err)
	}

	collection = bucket.DefaultCollection()
	log.Println("Successfully connected to Couchbase bucket:", cbBucket)

	// 2. Configure High-Performance Fiber Web Engine
	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
		Concurrency:           256 * 1024, // High concurrent connection limit
		ReadTimeout:           5 * time.Second,
		WriteTimeout:          5 * time.Second,
	})

	// Healthcheck endpoint
	app.Get("/health", func(c *fiber.Ctx) error {
		return c.SendString("OK")
	})

	// GET /api/orders/:id (60% Workload)
	app.Get("/api/orders/:id", func(c *fiber.Ctx) error {
		orderID := "ord::" + c.Params("id")
		var result map[string]interface{}
		
		_, err := collection.Get(orderID, &gocb.GetOptions{})
		if err != nil {
			if errors.Is(err, gocb.ErrDocumentNotFound) {
				// Treat missing doc as 200 OK (same behavior as our Java benchmark)
				return c.Status(200).JSON(fiber.Map{"status": "not_found"})
			}
			return c.Status(500).SendString(err.Error())
		}
		return c.Status(200).JSON(result)
	})

	// PUT /api/stock/:id (30% Workload)
	app.Put("/api/stock/:id", func(c *fiber.Ctx) error {
		itemID := "item::" + c.Params("id")
		doc := map[string]interface{}{
			"last_updated": time.Now().UnixNano() / int64(time.Millisecond),
			"status":       "FULFILLED",
		}

		_, err := collection.Upsert(itemID, doc, &gocb.UpsertOptions{})
		if err != nil {
			return c.Status(500).SendString(err.Error())
		}
		return c.SendStatus(200)
	})

	// POST /api/payments (10% Workload)
	app.Post("/api/payments", func(c *fiber.Ctx) error {
		txID := "tx::" + uuid.New().String()
		doc := map[string]interface{}{
			"tx_id":     txID,
			"amount":    10.0 + rand.Float64()*990.0,
			"timestamp": time.Now().UnixNano() / int64(time.Millisecond),
		}

		_, err := collection.Insert(txID, doc, &gocb.InsertOptions{})
		if err != nil {
			return c.Status(500).SendString(err.Error())
		}
		return c.Status(201).SendString(txID)
	})

	log.Printf("Starting Go Couchbase API Engine on port %s...", port)
	log.Fatal(app.Listen(":" + port))
}

func getEnv(key, fallback string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return fallback
}
