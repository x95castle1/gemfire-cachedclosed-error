# Geode 1.15 client CacheClosedException repro (k3d)

Reproduces this production error from a Geode 1.15 client on OpenShift:

```
org.apache.geode.cache.CacheClosedException: The cache is closed.
  at o.a.g.internal.cache.GemFireCacheImpl$Stopper.generateCancelledException(GemFireCacheImpl.java:5207)
  at o.a.g.CancelCriterion.checkCancelInProgress(CancelCriterion.java:83)
  at o.a.g.internal.cache.LocalRegion.checkRegionDestroyed(LocalRegion.java:7382)
  at o.a.g.internal.cache.LocalRegion.checkReadiness(LocalRegion.java:2788)
  at o.a.g.internal.cache.LocalRegion.newUpdateEntryEvent(LocalRegion.java:1676)
  at o.a.g.internal.cache.LocalRegion.put(LocalRegion.java:1636)
```

**Theory under test:**
1. When a pod is terminated, the JVM gets SIGTERM and runs all shutdown hooks at the same time.
2. Geode's hook ("Distributed system shutdown hook") closes the client cache.
3. Meanwhile Spring's hook is still finishing the HTTP requests already in progress, and the scheduled poller is still running.
4. Those requests and the poller then hit a closed cache.

For the Geode source analysis, the production checklist and the fix code, see [ANALYSIS.md](ANALYSIS.md).

## What's here

| Path | What it is |
|---|---|
| `app/` | Spring Boot 2.7 client with `geode-core:1.15.1`. `GET /account/{id}` sleeps 3s, then does `Account.put` (like `mapToResponse → putAccount`). A `Flux.interval` on `parallel-1` does `Config.get("CONFIG_TIMESTAMPpsg")` every second (like `ConfigListener`). |
| `geode-server/` | Apache Geode 1.15.1 locator and server in one image, with `Account` and `Config` regions. |
| `k8s/client-broken.yaml` | Today's setup: Geode shutdown hook on, no preStop, default 30s grace period. |
| `k8s/client-fixed.yaml` | The fix: preStop `sleep 15`, 60s grace period, `-Dgemfire.disableShutdownHook=true`, the poller disposed on `ContextClosedEvent`, and the cache closed in `@PreDestroy` after the graceful drain. |
| `k8s/load.yaml` | 10 curl workers sending requests through the Service without pause, so about 10 requests are always in flight. |

## Configurations

There are two client configurations. `broken` is how the app runs today and `fixed` has the proposed fixes. They are identical except for the first six rows:

| Setting | Where it's set | `broken` | `fixed` | Why it matters |
|---|---|---|---|---|
| **Geode JVM shutdown hook** | `JAVA_TOOL_OPTIONS` in `k8s/client-*.yaml` | On (default) | **Off**: `-Dgemfire.disableShutdownHook=true` | When on, it closes the cache the moment SIGTERM arrives |
| **Who closes the cache** | `app/.../GeodeCacheCloser.java` | Geode's hook, at SIGTERM | **Spring `@PreDestroy`**, after in-flight requests finish | This ordering is the actual fix |
| **Config poller** (`Flux.interval`) | `app/.../ConfigPoller.java` | Keeps running until the JVM exits | **Stopped on `ContextClosedEvent`**, before the drain | Stops the `get` errors on `parallel-1` |
| **preStop hook** | `k8s/client-*.yaml` | None | **`sleep 15`** | Lets the pod drop out of the Service before SIGTERM |
| **Grace period** (`terminationGracePeriodSeconds`) | `k8s/client-*.yaml` | 30s (default) | **60s** | Must cover preStop + drain + cache close, or the pod is SIGKILLed |
| `repro.mode` | `JAVA_TOOL_OPTIONS` | `broken` | `fixed` | Switches rows 2–3 on in the app |
| Spring graceful shutdown | `app/.../application.yml` | On, 20s timeout | On, 20s timeout | Same in both. On its own it doesn't help |
| `ClientCache` bean | `app/.../GeodeConfig.java` | `destroyMethod = ""` | `destroyMethod = ""` | Same in both. Spring doesn't close it, like a cache the ccp library creates |
| Liveness / readiness probes | `k8s/client-*.yaml` | `/actuator/health/*`, every 5s, 2 failures | Same | |
| Replicas / resources | `k8s/client-*.yaml` | 2 pods, 512Mi request / 1Gi limit | Same | |

How the scenarios combine them:

| Target | Config | Trigger | Simulates |
|---|---|---|---|
| `make broken-delete` | broken | `kubectl delete pod` under load | Rollout, scale-down, node drain |
| `make broken-liveness` | broken | Liveness probe forced to fail | kubelet restarting an unhealthy pod |
| `make fixed-delete` | fixed | `kubectl delete pod` under load | Same as above, with the fixes |
| `make fixed-liveness` | fixed | Liveness probe forced to fail | Same as above, with the fixes |
| `make broken-close-cache` | broken | `POST /admin/close-cache` | App or library code calling `cache.close()` while the pod keeps running |

Everything else is the same in all runs: the Geode 1.15.1 locator and server, the `Account` and `Config` regions, and 10 concurrent load workers sending 3s requests.

## Run it

Needs Docker Desktop, k3d, kubectl, Maven and JDK 17.

```bash
make up                  # k3d cluster "geode-repro" + images + Geode server (switches kubectl context)
make all                 # run all five scenarios (~7 min), then print the results table
make down                # delete the cluster
```

Other targets (`make` with no arguments lists them all):

| Target | What it does |
|---|---|
| `make broken-delete` | Today's config; the pod is deleted under load (like a rollout or scale-down) |
| `make broken-liveness` | Today's config; the liveness probe fails and the kubelet restarts the container |
| `make fixed-delete` / `make fixed-liveness` | The same two triggers with the fixed config |
| `make broken-close-cache` | App code calls `cache.close()` while the pod keeps running |
| `make broken` / `make fixed` | Both scenarios for that config |
| `make results` | One line per scenario from its latest run |
| `make rebuild` | Rebuild the client image after changing `app/` (the next run picks it up) |
| `make status` / `make stop-load` / `make clean-logs` | Show pods / stop the load pod / delete `logs/` |

Each run prints a summary. It saves `summary.txt`, `client.log`, `load.log`, `events.txt` and `describe.txt` under `logs/<mode>-<trigger>-<timestamp>/`. The same scenarios can also be run directly with `scripts/run.sh <broken|fixed> <delete|liveness|close-cache>`.

## Results (2026-09-24, k3d / k3s 1.30.3, Geode 1.15.1, JDK 17)

| Scenario | Failed puts | Failed polls | HTTP codes after trigger | Who closed the cache |
|---|---|---|---|---|
| broken / delete | 5 | 1 | 15×200, 5×500 | `Distributed system shutdown hook`, in the same ms as Spring's `Commencing graceful shutdown` |
| broken / liveness | 4 | 3 | 76×200, 4×500, 9×000 | Same as above. Exit code 143, `Liveness probe failed` → `Killing` |
| fixed / delete | 0 | 0 | 70×200 | `SpringApplicationShutdownHook`, after `Graceful shutdown complete` |
| fixed / liveness | 0 | 0 | 130×200, 9×000 | `SpringApplicationShutdownHook`, after a ~3s drain of in-flight requests |
| broken / close-cache | 33 | 18 | 27×200, 33×500 | `http-nio-8080-exec-7`. Pod stays Running/Ready, no events |

- **Same stack in every failing run.** Each one produced the production stack exactly (`GemFireCacheImpl.java:5207 … LocalRegion.put:1636`). The stack alone cannot tell the scenarios apart. The thread on the `Now closing.` line and whether `VM is exiting` appears before it can.
- **What the `000`s in the liveness runs are.** They are new connections refused after Tomcat stops accepting. A pod killed by its liveness probe stays in the Service endpoints, because it is still Ready. preStop can't fix that; only avoiding the liveness kill can.

## Reading the result, and matching it to production logs

| Signature in the client log | Meaning |
|---|---|
| `VM is exiting - shutting down distributed system`, then `GemFireCache[...]: Now closing.` on thread `[Distributed system shutdown hook]`, then `CacheClosedException` | Geode's JVM shutdown hook closed the cache during SIGTERM while work was still in flight (the shutdown race). |
| `Now closing.` on an app thread (for example `http-nio-8080-exec-*`), with no `VM is exiting`, and errors that continue while the pod stays Ready | Application code closed the cache (scenario 2). |
| `Now closing.` after `Graceful shutdown complete`, and no `CacheClosedException` | The fixed ordering. |

What to check in production:
- In `oc describe pod`, exit code 143 with `Liveness probe failed` / `Killing` events means the kubelet killed the pod. The `CacheClosedException` is then a symptom; the real problem is why the probe failed.
- Exit code 137 (SIGKILL or OOMKilled) never produces this exception, because no shutdown hook runs.
