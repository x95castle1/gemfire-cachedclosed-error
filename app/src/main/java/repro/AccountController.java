package repro;

import org.apache.geode.cache.Region;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/**
 * Mirrors CreditLimitIncreaseAggregatorImpl.mapToResponse -> CacheServiceImpl.putAccount: do slow
 * downstream work first, then write the result to the Account region.
 */
@RestController
public class AccountController {

  private static final Logger log = LoggerFactory.getLogger(AccountController.class);

  private final Region<String, String> accountRegion;
  private final long downstreamMillis;

  public AccountController(@Qualifier("accountRegion") Region<String, String> accountRegion,
      @Value("${repro.downstream-millis}") long downstreamMillis) {
    this.accountRegion = accountRegion;
    this.downstreamMillis = downstreamMillis;
  }

  @GetMapping("/account/{id}")
  public ResponseEntity<String> account(@PathVariable String id) throws InterruptedException {
    // Stands in for the Predecision API call that runs before the cache put.
    Thread.sleep(downstreamMillis);
    try {
      accountRegion.put(id, "account-" + id + "-" + System.currentTimeMillis());
      return ResponseEntity.ok("ok\n");
    } catch (RuntimeException e) {
      log.error("Exception occurred while mapping the response in Predecision API: "
          + "Exception while put Account:: ", e);
      return ResponseEntity.status(500).body(e + "\n");
    }
  }
}
