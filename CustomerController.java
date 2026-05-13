@RestController
@RequestMapping("/api/customer")
public class CustomerController {

    // VULNERABILITY: Hardcoded credentials (S2068)
    private static final String DB_PASSWORD = "Garanti123!";
    private static final String DB_URL = "jdbc:oracle:thin:@10.10.5.23:1521:ORCL";

    private static final Logger log = LoggerFactory.getLogger(CustomerController.class);

    @GetMapping("/search")
    public Customer searchCustomer(@RequestParam String tckn, @RequestParam String password) {
        Customer customer = null;
        try {
            Connection conn = DriverManager.getConnection(DB_URL, "admin", DB_PASSWORD);
            Statement stmt = conn.createStatement();

            // VULNERABILITY: SQL Injection (S3649) - Blocker
            String sql = "SELECT * FROM customers WHERE tckn = '" + tckn 
                       + "' AND password_hash = '" + hashPassword(password) + "'";
            ResultSet rs = stmt.executeQuery(sql);

            if (rs.next()) {
                customer = new Customer();
                customer.setTckn(rs.getString("tckn"));
                customer.setName(rs.getString("name"));
            }

            // BUG: Resource leak (S2095) - conn, stmt, rs kapatılmıyor
        } catch (Exception e) {
            // BUG: Empty catch / generic exception (S2221, S108)
        }

        // SECURITY HOTSPOT: Logging sensitive data (S5145)
        log.info("Customer searched: tckn={}, password={}", tckn, password);

        return customer;
    }

    private String hashPassword(String pwd) {
        try {
            // VULNERABILITY: Weak hashing algorithm MD5 (S4790) - Critical
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] hash = md.digest(pwd.getBytes());
            return new BigInteger(1, hash).toString(16);
        } catch (NoSuchAlgorithmException e) {
            e.printStackTrace(); // CODE SMELL: printStackTrace (S1148)
            return null; // BUG: Returning null (S2259 downstream)
        }
    }
}
