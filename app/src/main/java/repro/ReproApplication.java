package repro;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;

@SpringBootApplication
public class ReproApplication {

  private static final Logger log = LoggerFactory.getLogger(ReproApplication.class);

  @Value("${repro.mode}")
  private String mode;

  public static void main(String[] args) {
    SpringApplication.run(ReproApplication.class, args);
  }

  @EventListener(ApplicationReadyEvent.class)
  public void logMode() {
    log.info("REPRO mode={} gemfire.disableShutdownHook={}", mode,
        Boolean.getBoolean("gemfire.disableShutdownHook"));
  }
}
