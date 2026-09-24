package repro;

import javax.annotation.PreDestroy;

import org.apache.geode.cache.CacheClosedException;
import org.apache.geode.cache.client.ClientCache;
import org.apache.geode.cache.client.ClientCacheFactory;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * Fixed mode only: closes the Geode cache during bean destruction, which Spring runs after the
 * graceful HTTP drain. Pair with -Dgemfire.disableShutdownHook=true so Geode's own hook doesn't
 * close it first.
 */
@Component
@ConditionalOnProperty(name = "repro.mode", havingValue = "fixed")
public class GeodeCacheCloser {

  private static final Logger log = LoggerFactory.getLogger(GeodeCacheCloser.class);

  @PreDestroy
  public void closeCache() {
    try {
      ClientCache cache = ClientCacheFactory.getAnyInstance();
      log.info("REPRO closing Geode client cache from Spring @PreDestroy");
      cache.close();
    } catch (CacheClosedException alreadyClosed) {
      // nothing to do
    }
  }
}
