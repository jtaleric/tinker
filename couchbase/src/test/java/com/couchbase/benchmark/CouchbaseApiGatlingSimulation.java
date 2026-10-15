package com.couchbase.benchmark;

import io.gatling.javaapi.core.*;
import io.gatling.javaapi.http.*;

import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;

import static io.gatling.javaapi.core.CoreDsl.*;
import static io.gatling.javaapi.http.HttpDsl.*;

public class CouchbaseApiGatlingSimulation extends Simulation {

    private static final String API_URL = System.getenv().getOrDefault(
            "API_URL", 
            "http://cb-go-api-service.couchbase-cudn.svc.cluster.local:8080"
    );

    private static final int TARGET_TPS = Integer.parseInt(
            System.getenv().getOrDefault("TARGET_TPS_PER_POD", "25000")
    );

    private static final int RAMP_DURATION_SECS = Integer.parseInt(
            System.getenv().getOrDefault("RAMP_DURATION_SECS", "30")
    );

    private static final int TEST_DURATION_MINS = Integer.parseInt(
            System.getenv().getOrDefault("TEST_DURATION_MINS", "10")
    );

    // Thread-safe 1-Second Aggregated Metrics Reporter
    public static class MetricsReporter {
        private static final ConcurrentLinkedQueue<Integer> latenciesMs = new ConcurrentLinkedQueue<>();
        private static final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();

        static {
            scheduler.scheduleAtFixedRate(() -> {
                int count = latenciesMs.size();
                if (count == 0) return;

                List<Integer> samples = new ArrayList<>(count);
                Integer val;
                while ((val = latenciesMs.poll()) != null) {
                    samples.add(val);
                }

                if (samples.isEmpty()) return;

                Collections.sort(samples);
                int size = samples.size();
                int min = samples.get(0);
                int max = samples.get(size - 1);
                long sum = 0;
                for (int l : samples) sum += l;
                double mean = (double) sum / size;

                int p95Index = (int) Math.min(size - 1, Math.floor(size * 0.95));
                int p99Index = (int) Math.min(size - 1, Math.floor(size * 0.99));
                int p95 = samples.get(p95Index);
                int p99 = samples.get(p99Index);

                System.out.printf("[SUMMARY-1S] TPS: %d req/s | Min: %dms | Max: %dms | Mean: %.2fms | p95: %dms | p99: %dms%n",
                        size, min, max, mean, p95, p99);
            }, 1, 1, TimeUnit.SECONDS);
        }

        public static void record(Integer latencyMs) {
            if (latencyMs != null) {
                latenciesMs.add(latencyMs);
            }
        }
    }

    HttpProtocolBuilder httpProtocol = http
            .baseUrl(API_URL)
            .shareConnections()
            .maxConnectionsPerHost(100000)
            .disableWarmUp()
            .disableCaching();

    ScenarioBuilder scn = scenario("Couchbase Workload Mixture")
            .randomSwitch().on(
                percent(60.0).then(
                    exec(
                        http("GET /api/orders/:id")
                            .get(session -> "/api/orders/" + (ThreadLocalRandom.current().nextInt(100000) + 1))
                            .check(status().is(200))
                            .check(responseTimeInMillis().saveAs("rt"))
                    ).exec(session -> {
                        if (session.contains("rt")) {
                            MetricsReporter.record(session.getInt("rt"));
                        }
                        return session;
                    })
                ),
                percent(30.0).then(
                    exec(
                        http("PUT /api/stock/:id")
                            .put(session -> "/api/stock/" + (ThreadLocalRandom.current().nextInt(10000) + 1))
                            .check(status().is(200))
                            .check(responseTimeInMillis().saveAs("rt"))
                    ).exec(session -> {
                        if (session.contains("rt")) {
                            MetricsReporter.record(session.getInt("rt"));
                        }
                        return session;
                    })
                ),
                percent(10.0).then(
                    exec(
                        http("POST /api/payments")
                            .post("/api/payments")
                            .check(status().is(201))
                            .check(responseTimeInMillis().saveAs("rt"))
                    ).exec(session -> {
                        if (session.contains("rt")) {
                            MetricsReporter.record(session.getInt("rt"));
                        }
                        return session;
                    })
                )
            );

    {
        setUp(
            scn.injectOpen(
                rampUsersPerSec(1000).to(TARGET_TPS).during(Duration.ofSeconds(RAMP_DURATION_SECS)),
                constantUsersPerSec(TARGET_TPS).during(Duration.ofMinutes(TEST_DURATION_MINS))
            )
        ).protocols(httpProtocol);
    }
}
