package repro;

import java.time.Duration;

import org.apache.geode.cache.Region;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.ContextClosedEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import reactor.core.Disposable;
import reactor.core.publisher.Flux;

/**
 * Mirrors ConfigListener: a Flux.interval on the Reactor parallel scheduler (thread "parallel-1")
 * that reads CONFIG_TIMESTAMPpsg from the Config region.
 */
@Component
public class ConfigPoller {

  private static final Logger log = LoggerFactory.getLogger(ConfigPoller.class);
  private static final String KEY = "CONFIG_TIMESTAMPpsg";

  private final Region<String, String> configRegion;
  private final boolean fixed;
  private volatile Disposable poller;

  public ConfigPoller(@Qualifier("configRegion") Region<String, String> configRegion,
      @Value("${repro.mode}") String mode) {
    this.configRegion = configRegion;
    this.fixed = "fixed".equals(mode);
  }

  @EventListener(ApplicationReadyEvent.class)
  public void start() {
    poller = Flux.interval(Duration.ofSeconds(1))
        .doOnNext(tick -> checkLatestTimestamp())
        .subscribe();
  }

  // ContextClosedEvent is published before the web server drains and before beans are destroyed.
  @EventListener(ContextClosedEvent.class)
  public void stop() {
    Disposable p = poller;
    if (fixed && p != null) {
      p.dispose();
      log.info("REPRO config poller stopped");
    }
  }

  private void checkLatestTimestamp() {
    try {
      configRegion.get(KEY);
    } catch (RuntimeException e) {
      log.error("Error occurred during scheduled task execution : ",
          new RuntimeException("Error encountered during get operation for key: " + KEY, e));
    }
  }
}
