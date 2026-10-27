GATE: SL-CORRECTION
APPROVER: Koka Easwarendra <easwarendra.ece@gmail.com>
DATE: 2026-10-28

This record authorizes the Scope-A security-list corrections documented in
docs/acceptance/m1-local/scope-a-network-execution-approval.md §6, executed only via
scripts/ops/eventforge-sl-update (which re-verifies every hash below against the live
object before any write and refuses any concurrent change).

Manifests approved (recorded rule-array hashes — immutable artifacts):

- lb-sl-manifest.json
  security_list_id: ocid1.securitylist.oc1.ap-hyderabad-1.aaaaaaaaelahefjk6ddczauhmu4tznf6pocrtkb7h26ihs2i4nlafoibdsya
  ingress_hash: fb6f4a1992d372c22ba9a305ae0956fee4a09bbc78c0f04f9708177a701fc679
  egress_hash: 416ab7f0baf5299edde0db3d41fa645e9aa03e64311225ea568e3232d8aaac36
- app-sl-manifest.json
  security_list_id: ocid1.securitylist.oc1.ap-hyderabad-1.aaaaaaaairrc6gzsc5emsx6hhvajcd6nmmagbgqf2qy5zvb77dqrfo63sm3q
  ingress_hash: 7834d1bff1e243e2366a9a90a1c3dcd92a0e4c947683069b9ad9238079b8ca49
  egress_hash: 416ab7f0baf5299edde0db3d41fa645e9aa03e64311225ea568e3232d8aaac36
- db-sl-manifest.json
  security_list_id: ocid1.securitylist.oc1.ap-hyderabad-1.aaaaaaaarwcfapns7orc6hvovfrt2md3xhko443sp5vz324b5c7pwiu7apoa
  ingress_hash: 15745b0db084c807627716105d5cbf7a57184c582a777c65150ccaa68189fabd
  egress_hash: 416ab7f0baf5299edde0db3d41fa645e9aa03e64311225ea568e3232d8aaac36

The Terraform NSG-association apply (A2) has been completed and verified before this
record takes effect (separate PLATFORM-APPLY record
[scope-a-apply-approval.md](scope-a-apply-approval.md), plan SHA-256
8cce2da3dc56e420070ebf6016c14f5eca4b5fe0b1f528ecdb58c796e949cfa6, serial 12;
A3 verification: NSG memberships live on both VM VNICs and the LB, real SSH from the
approved /32 to both VMs, MySQL path proven from both VMs, m1-verify 18 PASS / 0 FAIL).
The DB-NSG attachment to MySQL is BLOCKED at the service level (blockers.md B5) and is
not part of this record; the db security list keeps 3306 from the app subnet as the
governing control, exactly as the approved package specifies.

Dated statement: I reviewed the captured live security-list objects, the proposed rule
arrays, and the stop conditions, and I authorize exactly these three corrections — no
other security list, no other rule, no ingress enablement.
