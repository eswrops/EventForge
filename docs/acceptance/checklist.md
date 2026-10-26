# M1A acceptance checklist

Record the starting commit, command line, report hash, reviewer, and date with each completed item.

- [ ] Baseline: repository status, Terraform roots, workflows, pins, and starting commit captured in [baseline.md](baseline.md).
- [ ] Offline harness report has no `FAIL` entries; every `NOT_RUN` is explained and re-run where possible.
- [ ] WIF fixtures cover malformed config, missing fields, expired tokens, unexpected repository/environment claims, and failed RPST exchange.
- [ ] Safe-plan fixtures cover no-op, imported resource, approved and unexpected creates, update, both replacement orderings, unknown ingress attributes, malformed JSON, public 8080/3306 ingress, narrow ingress, and certificate-generation review.
- [ ] All three backend keys are distinct (`bootstrap/`, `platform/`, and `frontend/`); state bucket versioning and customer-managed encryption evidence is retained.
- [ ] OCI plan and apply trusts are separate and restricted to their corresponding protected GitHub environment subjects.
- [ ] No API ingress or application deployment was enabled by this acceptance activity.
- [ ] The operator-approved live runbook has been completed or every unperformed live step is called out as a blocker.
