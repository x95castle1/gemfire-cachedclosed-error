# Geode 1.15 client `CacheClosedException`: analysis, what to collect, and fixes

The production error, seen from a Geode 1.15 client on OpenShift:

```
org.apache.geode.cache.CacheClosedException: The cache is closed.
  at o.a.g.internal.cache.GemFireCacheImpl$Stopper.generateCancelledException(GemFireCacheImpl.java:5207)
  at o.a.g.CancelCriterion.checkCancelInProgress(CancelCriterion.java:83)
  at o.a.g.internal.cache.LocalRegion.checkRegionDestroyed(LocalRegion.java:7382)
  at o.a.g.internal.cache.LocalRegion.checkReadiness(LocalRegion.java:2788)
  at o.a.g.internal.cache.LocalRegion.newUpdateEntryEvent(LocalRegion.java:1676)
  at o.a.g.internal.cache.LocalRegion.put(LocalRegion.java:1636)          <- and LocalRegion.get(LocalRegion.java:1366)
```

For how to reproduce it, and the results, see [README.md](README.md).

## What the stack trace proves

These line numbers match every 1.15.x release exactly (`rel/v1.15.0` through `rel/v1.15.3`).

- **The error comes from the client itself, not the servers.** Both `put` and `get` fail in `LocalRegion.checkReadiness()`, which runs before any network call.
- **The cache was closed with no failure cause attached.**
  - `GemFireCacheImpl.java:5207` is the branch where `disconnectCause == null`.
  - A client's `LonerDistributionManager` never supplies a cancel reason, so the message "The cache is closed." can only come from `isClosing == true`.
  - That flag is set only in `GemFireCacheImpl.doClose()` (line 2206, which logs `"<cache>: Now closing."`).
- **Several causes are ruled out.** Each would have produced a different message or a `Caused by` chain:
  - out-of-memory or another `VirtualMachineError` (`emergencyClose` sets `disconnectCause`)
  - a `DiskAccessException` (`DiskStoreImpl.java:3359` passes the exception as the cause)
  - a forced disconnect (that only happens to peers, not clients)
  - ShutdownAll (message "Cache is being closed by ShutdownAll")
  - losing all servers (the client pool never closes the cache)
- **Only two things can produce this exception:**
  1. **Geode's JVM shutdown hook.** `InternalDistributedSystem.java:2179-2204`, thread `Distributed system shutdown hook`, logs `VM is exiting - shutting down distributed system`. It runs on SIGTERM, *at the same time as* Spring's own shutdown hook, which is still finishing in-flight requests. **This is reproduced in this project.**
  2. **Application or framework code calling `ClientCache.close()`.** The cache is one per JVM, so any component that closes "its" cache closes it for every user of the JVM. Related case: a `Region` reference kept after the cache was re-created.

**How to tell the two apart in production:** find the `Now closing.` log line.
- If it's on thread `[Distributed system shutdown hook]` and follows `VM is exiting`, it's the shutdown race.
- If it's on an application thread (for example `http-nio-*`) and the pod stays up while errors continue, application code closed the cache.

The stack trace is identical in both cases.

## What to collect in production

**Client logs.** If the container restarted, use `oc logs <pod> --previous`.
- Look for `Now closing` and note the thread name on that line.
- Look for `VM is exiting - shutting down distributed system`, `Normal disconnect` and `Exception trying to close cache`.
- Check for a second cache startup banner, which would mean the cache was re-created.
- Compare the time of the first `CacheClosedException` with the pod's termination time.

**OpenShift**
- `oc describe pod <pod>` shows the restart count, the last state's reason and the exit code:
  - **143** = SIGTERM. Shutdown hooks ran, so this failure mode applies.
  - **137** = SIGKILL or OOMKilled. No hooks ran, so this exception wouldn't appear.
- Events to look for: `Liveness probe failed`, `Killing`, `Evicted`, `Preempting`.
- `oc get events --sort-by=.lastTimestamp`, rollout history, HPA scale-downs and node drains around the incident time.
- The pod's `terminationGracePeriodSeconds`, its `preStop` hook, and its probe thresholds.
- Whether the container entrypoint starts Java with `exec` (or uses the exec form), so that the JVM is the process that receives SIGTERM.

**Configuration**
- Is `-Dgemfire.disableShutdownHook` set? Only the `gemfire.` prefix is read (`InternalDistributedSystem.java:384`).
- Spring's `server.shutdown` and `spring.lifecycle.timeout-per-shutdown-phase` settings.
- How the `ClientCache` bean is created and destroyed.
- In the ccp cache library:
  - any `close()`, `disconnect()`, `CacheManager.close` or reconnect logic
  - whether `JCache` keeps `Region` references instead of looking them up again

If the pod was killed by its liveness probe, the `CacheClosedException` is only a symptom. The real question is why the probe failed (GC pauses, blocked threads, slow downstream calls).

## Fixes (validated in this repro; see README results)

Target shutdown order:

> pod removed from Service/Route → preStop sleep → SIGTERM → poller stops → HTTP drain → cache closed by Spring → JVM exits

### 1. preStop sleep and grace period (`spec.template.spec`)

```yaml
terminationGracePeriodSeconds: 60   # default 30; must cover preStop + Spring drain + cache close
containers:
  - name: app
    lifecycle:
      preStop:
        exec:
          command: ["sh", "-c", "sleep 15"]   # image needs sh + sleep (UBI images have them)
```

On Kubernetes 1.30+ / OpenShift 4.17+ there is a built-in sleep action that needs no shell:

```yaml
    lifecycle:
      preStop:
        sleep:
          seconds: 15
```

The grace period countdown includes the preStop time. With 15s of preStop, a 20s drain and the default 30s grace period, the pod gets SIGKILLed partway through.

### 2. Disable Geode's JVM shutdown hook

Only do this together with step 4, so that something still closes the cache.

```yaml
    env:
      - name: JAVA_TOOL_OPTIONS            # or JAVA_OPTS_APPEND on Red Hat OpenJDK images
        value: "-Dgemfire.disableShutdownHook=true"
```

Or set it in code. This must run before any Geode class loads, because the flag is read in a static initializer:

```java
public static void main(String[] args) {
  System.setProperty("gemfire.disableShutdownHook", "true");
  SpringApplication.run(Application.class, args);
}
```

### 3. Spring Boot graceful shutdown (`application.yml`, Boot 2.3+)

```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 20s
```

### 4. Close the cache from Spring after the drain

Spring destroys beans after the web server's graceful stop:

```java
@Bean(destroyMethod = "close")
public ClientCache clientCache() {
  return new ClientCacheFactory()
      // ...existing pool/locator config...
      .create();
}
```

If the cache is created outside Spring (for example by the ccp library), use a separate bean instead. The repro version of this is `app/src/main/java/repro/GeodeCacheCloser.java`.

```java
@Component
class GeodeCacheCloser {
  @PreDestroy
  void closeCache() {
    try {
      ClientCache cache = ClientCacheFactory.getAnyInstance(); // throws CacheClosedException if none open
      cache.close();                                           // close(true) for durable clients
    } catch (CacheClosedException alreadyClosed) {
      // nothing to do
    }
  }
}
```

### 5. Stop scheduled pollers first

`ContextClosedEvent` is published before the drain. The repro version of this is `app/src/main/java/repro/ConfigPoller.java`.

```java
private volatile Disposable poller;

// where the Flux.interval is started today:
poller = Flux.interval(Duration.ofSeconds(30))
    .doOnNext(tick -> checkLatestTimestamp())
    .subscribe();

@EventListener(ContextClosedEvent.class)
public void stopPolling() {
  Disposable p = poller;
  if (p != null) {
    p.dispose();
  }
}
```

### Known limit

A pod killed by its **liveness probe** stays in the Service endpoints (it is still Ready). New connections that arrive after Tomcat stops accepting are refused; the repro shows these as `000`. The fixes above prevent the `CacheClosedException`, but not those refusals. The only fix for those is to stop the liveness probe from failing.
