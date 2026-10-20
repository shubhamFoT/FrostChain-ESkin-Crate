# Before you tag `stage2-submission` (delete this file afterwards)

## Missing files
- [ ] KiCad project (`02_electronics/kicad/`) and ERC/DRC reports (`02_electronics/drc/`)
- [ ] Scripts that generate both plots (`03_models_and_plots/scripts/`)
- [ ] FEA study, convergence plot and mesh stats (`01_mechanical/fea/`)
- [ ] Lab photos with ID badges, CAD feature-tree and EDA screenshots (`05_docs/evidence/`)
- [ ] Fill every [PLACEHOLDER] in `README.md` and `LICENSE`

## Consistency fixes (judges will cross-check)
- [ ] STEP part names are timestamps (e.g. `2026-10-19-23-57-47-023`). Rename components in Fusion (Crate_Body, Lid, PCM_Pack_1...) and re-export the STEP.
- [ ] Thermistor: schematic TH1 = 100 kOhm, BOM = 10 kOhm NTC. Pick one.
- [ ] Reference designators differ between BOM and schematic (BTS7960 U5 vs U8; modem M1 vs U5; MPPT U_MPPT vs U1; LM2596 U1/U2 vs U2).
- [ ] BOM line quantities sum to 41; the total row says 40.
- [ ] Verify the CN3791 board can be configured for 4S LiFePO4 at 14.4 V (many are single-cell).
- [ ] Schematic block 5 says "5G / LTE (SIM7600 class)"; SIM7600 is 4G LTE. Label consistently with the BOM.

## Git hygiene
- Commit as you produce each piece of work; do not push everything in one commit; never backdate.
- Make the repo public (or add judges as collaborators) and test the link in an incognito window.
- Tag the final state: `git tag -a stage2-submission -m "Stage 2 submission" && git push origin stage2-submission`
- Put the tag URL + QR code on the Maker Journey slide.
