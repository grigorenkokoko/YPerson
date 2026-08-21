# YPerson — package 1 physical-device checks

These checks are intentionally unchecked. Apply the versioned YDB schema before deploying the matching backend and gateway, then record the date, iOS versions, build number, and pass/fail on physical iPhones. Local tests and an unsigned simulator build are not evidence for these checks.

- [ ] Safari fetches AASA directly with HTTP 200, application/json, and no redirect.
- [ ] Camera on iPhone without YPerson opens the mobile HTML card.
- [ ] Camera on iPhone with YPerson opens the native confirmation screen.
- [ ] Downloaded vCard imports only the approved public fields.
- [ ] Valid reply appears after owner foreground refresh and is saved only after confirmation.
- [ ] Revoke makes HTML, JSON, vCard, and new reply submission unavailable.
