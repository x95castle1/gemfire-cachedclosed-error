package repro;

import org.apache.geode.cache.client.ClientCache;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.availability.AvailabilityChangeEvent;
import org.springframework.boot.availability.LivenessState;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class AdminController {

  private static final Logger log = LoggerFactory.getLogger(AdminController.class);

  private final ApplicationEventPublisher publisher;
  private final ClientCache cache;

  public AdminController(ApplicationEventPublisher publisher, ClientCache cache) {
    this.publisher = publisher;
    this.cache = cache;
  }

  /** Makes /actuator/health/liveness return DOWN so the kubelet restarts the container. */
  @PostMapping("/admin/break-liveness")
  public String breakLiveness() {
    log.info("REPRO liveness set to BROKEN");
    AvailabilityChangeEvent.publish(publisher, this, LivenessState.BROKEN);
    return "liveness BROKEN\n";
  }

  /** Scenario 2: application code closes the cache while the process keeps running. */
  @PostMapping("/admin/close-cache")
  public String closeCache() {
    log.info("REPRO closing cache from application code");
    cache.close();
    return "cache closed\n";
  }
}
