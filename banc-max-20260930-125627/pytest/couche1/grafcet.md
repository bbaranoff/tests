# GRAFCET — go-live DSP & chaîne I/Q

*Auto-généré par `tests/conftest.py::pytest_sessionfinish` — statut dérivé des logs du dernier run (20260930_125905).*

- delta FN-ALIGN : **None**  ·  LOST : **0**

```mermaid
flowchart TD
  classDef src  fill:#12242f,stroke:#6ea8d8,stroke-width:1px,color:#cfe3f2;
  classDef ok   fill:#0f2620,stroke:#46c39a,stroke-width:1px,color:#bfe9d7;
  classDef wip  fill:#2a2211,stroke:#e6a94e,stroke-width:1px,color:#f0d6a4;
  classDef bad  fill:#2a1412,stroke:#e86a5f,stroke-width:1.4px,color:#f2c3bd;
  classDef join fill:#101d22,stroke:#38d3c2,stroke-width:1.4px,color:#bff0ea;

  E0["BTS emet en continu<br/>SI3 - FCCH - SCH - FN reelle"]:::src
  E0 -->|I/Q air| P1["ipc-device sert l'I/Q<br/>qfn-serve - FCCH"]:::ok
  P1 -->|FIFO iq_grgsm| G1["gr-gsm decode la SCH<br/>BSIC=7 - sch_fn"]:::ok
  G1 -->|"DL_FN_OFFSET=-556"| F1["FN-ALIGN recale FN<br/>delta None"]:::bad
  P1 -. "UDP :6702 -- NON CABLE" .-> B1["BSP bsp_trxd_readable<br/>RXSZ = 0"]:::bad
  B1 --> B2["feed_iq -> last_pm<br/>PM = 0 dBm"]:::bad
  B2 --> B3["rx_burst -> DARAM 0x2a00<br/>entree correlateur"]:::bad

  A0["init go-live 0xa4c7<br/>ORM/RSBX/IMR"]:::ok
  A0 -->|"CTRLSYS pose 0x0810 bit15"| A1["gate 0xa53c BITF<br/>TC=1 - bootstrap"]:::bad
  A1 -->|"KEEP_IMR - FRAME_IT_NATIVE"| A2["IMR=0x52fd - BRINT0 arme<br/>INTM natif - LOST =0"]:::ok
  A2 -->|"TASKW d[3f92]=0x0800"| A3["task_md=5 dispatche<br/>CALA 0xb01e -> 0x8d00"]:::bad
  A3 -->|"FBEN d[3fab] bit8"| A4["gate 0x3fab bit8<br/>vers kernel"]:::bad

  B3 --> K["CORRELATEUR FB"]:::join
  A4 --> K
  K -. "AR5 =0xdb7b (garbage)<br/>kernel 0xa076 jamais atteint" .-> KB["fb0_ret = 0"]:::wip
  KB --> D["d_fb_det"]:::bad
  D --> Mn["mobile campe<br/>normal service"]:::ok

  linkStyle default stroke:#3a565d,stroke-width:1.3px;
```

## Rang de blocage · gates

| Rang | Maillon | Gate / wire | État |
|------|---------|-------------|------|
| RANK1 | Pont ARM->DSP d_ctrl_system - gate go-live 0xa53c (bit15 de 0x0810) | `CALYPSO_ARM2DSP_CTRLSYS=1` | `MANQUANT` |
| RANK4 | Recalage FN DSP/TRX sur la SCH - offset constant -556 | `CALYPSO_DL_FN_OFFSET=-556` | `MANQUANT` |
| - | Cadence timer - LOST N! (batching frame-IRQ) | `latch read-driven (-1875/lecture)` | `CABLE` |
| RANK3 | Dispatch handler 0x8d00 -> kernel MAC 0xa076 (AR5=0x2a00) | `TASKW / FBEN (d[3f92], d[3fab] bit8)` | `EN COURS` |
| RANK2 | Entree I/Q DL du BSP - forward producteur -> UDP :6702 | `- (aucun forward)` | `MANQUANT` |
| RANK5 | PM / rxlev legitime (last_pm depuis le vrai I/Q) | `depend de RANK2 (feed_iq)` | `MANQUANT` |

> Convergence au corrélateur : dispatch (go-live) ∧ entrée I/Q (signal). Le verrou courant
> est l'entrée I/Q DL du BSP (`UDP :6702` non câblé) et le dispatch handler→kernel (`AR5`).
