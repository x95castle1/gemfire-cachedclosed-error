package repro;

import org.apache.geode.cache.Region;
import org.apache.geode.cache.client.ClientCache;
import org.apache.geode.cache.client.ClientCacheFactory;
import org.apache.geode.cache.client.ClientRegionShortcut;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class GeodeConfig {

  // destroyMethod = "" keeps Spring from closing the cache or regions, the same as a cache
  // created by a library outside the Spring lifecycle. Only the Geode JVM shutdown hook (broken
  // mode) or GeodeCacheCloser (fixed mode) closes it.
  @Bean(destroyMethod = "")
  public ClientCache clientCache(@Value("${geode.locator.host}") String locatorHost,
      @Value("${geode.locator.port}") int locatorPort) {
    return new ClientCacheFactory()
        .addPoolLocator(locatorHost, locatorPort)
        .setPoolReadTimeout(10_000)
        .create();
  }

  @Bean(destroyMethod = "")
  public Region<String, String> accountRegion(ClientCache cache) {
    return cache.<String, String>createClientRegionFactory(ClientRegionShortcut.PROXY)
        .create("Account");
  }

  @Bean(destroyMethod = "")
  public Region<String, String> configRegion(ClientCache cache) {
    return cache.<String, String>createClientRegionFactory(ClientRegionShortcut.PROXY)
        .create("Config");
  }
}
