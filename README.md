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

Both modes use `server.shutdown=graceful`.

## Run it

Needs Docker Desktop, k3d, kubectl, Maven and JDK 17.

```bash
scripts/cluster-up.sh              # k3d cluster "geode-repro" + images + Geode server (switches kubectl context)

scripts/run.sh broken delete       # kubectl delete pod under load
scripts/run.sh broken liveness     # liveness probe failure -> kubelet restart
scripts/run.sh fixed  delete
scripts/run.sh fixed  liveness
scripts/run.sh broken close-cache  # app code closes the cache while the pod stays up

scripts/cluster-down.sh
```

Each run prints a summary and saves `client.log`, `load.log`, `events.txt` and `describe.txt` under `logs/<mode>-<trigger>-<timestamp>/`.

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
