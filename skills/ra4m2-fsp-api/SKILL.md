---
name: ra4m2-fsp-api
description: Renesas RA4M2 (RA family, Cortex-M33) peripheral configuration and FSP API reference. Use when writing or changing RA firmware - GPIO, external IRQ, GPT/AGT timers and PWM, UART with printf retargeting, I2C sensors, RTC, ADC, or watchdog - and when calculating PWM frequency/duty, ADC voltage conversion, or watchdog timeouts. Includes the clock facts, API call sequences and known gotchas that generic answers get wrong.
whenToUse: The user is writing or modifying RA4M2 / RA-family FSP firmware, needs a pin or peripheral configured, needs a PWM / ADC / watchdog calculation, or hits an FSP API misuse error.
---

# RA4M2 + FSP API reference

## Two kinds of facts — keep them separate

**Chip-level facts** (true for any RA4M2 design): memory map, peripheral set, API surface,
timer resolution, watchdog clock sources.

**Board-level facts** (true only for a specific PCB): which pin the LED is on, whether the
LED is active-high, which pin the button is on, which pins are wired to a sensor.

**Never assume board-level facts.** Read them from, in order:
1. The board's schematic (ask the user for the file, or find it in the project repo — often
   a `*原理图*` / `*schematic*` PDF, or a board pinout table in the README)
2. `ra_gen/pin_data.c` and `ra_gen/hal_data.c` in the project — the generated truth
3. `configuration.xml` — the configurator's own record
4. The user

If you truly cannot determine a pin, say so and ask. Do not invent a pin number.

> Example of a board-level table, from one particular RA4M2 teaching board. **Verify
> against the actual board before using these numbers:**
>
> | Resource | Pin | Note |
> |---|---|---|
> | LED | P111 | active-high |
> | Button | P000 | pulled up, pressed = low |
> | UART | SCI9 | via CH340 USB-serial bridge |
> | I2C | SCL P301, SDA P302, addr-strap P500 | |
> | ADC | AN012 P014, AN013 P015 | 12-bit |
> | PWM out | GPT3 / AGT5 → P111 | |
> | Input capture | GPT6, signal on P408 | |

---

## Clock facts (chip-level)

Typical RA4M2 configuration in e² studio projects:

| Clock | Typical value | Used by |
|---|---|---|
| XTAL (external crystal) | **must match the physical crystal** | source for the PLL |
| PCLKD | 90 MHz (÷2 of the 180 MHz system clock) | **GPT** timers |
| PCLKB | 45 MHz (÷4) | **AGT** timers, some serial |

**Check the actual numbers in the project's clock configuration** — do not assume 90/45 MHz.
If XTAL is wrong, the baud rate and every software delay are wrong too.

---

## Calculation reference

| Quantity | Formula |
|---|---|
| PWM frequency | `frequency = timer_clock / period` |
| PWM duty | `duty = cycle / period` |
| GPT 10 kHz @ 90 MHz | `period = 90e6 / 10e3 = 9000` |
| GPT 25% @ that period | `cycle = 0.25 × 9000 = 2250` |
| AGT 10 kHz @ 45 MHz | `period = 45e6 / 10e3 = 4500` |
| AGT 25% @ that period | `cycle = 0.25 × 4500 = 1125` |
| ADC → volts | `volts = raw / (2^bits - 1) × VREF` — for 12-bit @3.3 V: `raw / 4095 × 3.3` |
| Watchdog timeout | `(divider_cycles × timeout_cycles) / watchdog_clock_hz` |

**Watchdog clock sources differ — this is the classic mistake:**

| | WDT | IWDT |
|---|---|---|
| Clock | PCLKB (may stop with the system) | dedicated IWDTCLK (independent) |
| Counts | down, 100% → 0% | down, 100% → 0% |
| Typical timeout | tens of seconds | a few seconds |

- The counter counts **down**, so a small reading is normal.
- **A debugger halts the watchdog by default** — it will appear "not working" under J-Link.
  To keep it running while debugging: `R_DEBUG->DBGSTOPCR_b.DBGSTOP_WDT = 0;` (and
  `DBGSTOP_IWDT` for IWDT).

---

## FSP coding pattern

Every peripheral follows **Open → (configure) → Start → main loop**.

```c
void hal_entry(void)
{
    fsp_err_t err = FSP_SUCCESS;

    err = R_XXX_Open(&g_xxx_ctrl, &g_xxx_cfg);
    assert(FSP_SUCCESS == err);          /* <- your best debugging tool */

    (void) R_XXX_Start(&g_xxx_ctrl);

    while (1) { }
}
```

`assert(FSP_SUCCESS == err)` hanging tells you exactly which `Open` failed. Usual causes:
a pin claimed by two peripherals, a duplicated channel, an unconfigured clock, or the wrong
peripheral type (GPT vs AGT).

### GPT — general PWM timer (high precision, 32-bit capable)

```c
R_GPT_Open(&g_timer_ctrl, &g_timer_cfg);      /* must precede Start */
R_GPT_Start(&g_timer_ctrl);                   /* else FSP_ERR_NOT_OPEN */
R_GPT_PeriodSet(&g_timer_ctrl, period);       /* frequency */
R_GPT_DutyCycleSet(&g_timer_ctrl, cycle, GPT_IO_PIN_GTIOCA);
R_GPT_Reset(&g_timer_ctrl);                   /* make changes take effect now */
R_GPT_Close(&g_timer_ctrl);
```

Period/duty take effect **on the next overflow**. To apply immediately, call `R_GPT_Reset()`.
Allowing a short delay between configuration calls is more reliable than immediate re-config.

Breathing LED: ramp a duty counter up and down in the main loop, calling
`R_GPT_DutyCycleSet` each iteration, with a small delay setting the speed.

### AGT — asynchronous general timer (low power, 16-bit)

Same shape, different prefix and output-pin macro:

```c
R_AGT_Open(&g_timer_ctrl, &g_timer_cfg);
R_AGT_Start(&g_timer_ctrl);
R_AGT_PeriodSet(&g_timer_ctrl, period);
R_AGT_DutyCycleSet(&g_timer_ctrl, cycle, AGT_OUTPUT_PIN_AGTOA);
```

**Choosing between them**

| | GPT | AGT |
|---|---|---|
| Low-power modes | runs in sleep | runs in **all** low-power modes |
| Channels | many (≥7 on most parts) | 2 |
| Width | at least one 32-bit | 16-bit |
| Clock source | PCLKD (÷ up to 1024), ELC/external pulse | PCLKB, LOCO, or subclock |

Low power → AGT. Precision or many channels → GPT. **Do not mix the API prefixes** — using
`R_GPT_*` on an AGT instance (or the wrong output-pin macro) will not compile or will target
the wrong peripheral.

### UART + printf retargeting

```c
volatile bool tx_done = false;
void user_uart_callback(uart_callback_args_t *p_args) {
    if (p_args->event == UART_EVENT_TX_COMPLETE) tx_done = true;
}

#include <stdio.h>
#ifdef __GNUC__
#define PUTCHAR_PROTOTYPE int __io_putchar(int ch)
#else
#define PUTCHAR_PROTOTYPE int fputc(int ch, FILE *f)
#endif

PUTCHAR_PROTOTYPE {
    err = R_SCI_UART_Write(&g_uart_ctrl, (uint8_t *)&ch, 1);
    if (FSP_SUCCESS != err) __BKPT();
    while (!tx_done) { }
    tx_done = false;
    return ch;
}

int _write(int fd, char *pBuffer, int size) {
    for (int i = 0; i < size; i++) __io_putchar(*pBuffer++);
    return size;
}
```

Three prerequisites for `printf`: `#include <stdio.h>`, the `__io_putchar` retarget, and
the `_write` shim. Plus **`-u _printf_float` in the linker options** if you print floats,
and **enough stack** (printf uses varargs).

### UART receive

```c
/* fixed length: complete on UART_EVENT_RX_COMPLETE */
R_SCI_UART_Read(&g_uart_ctrl, dest, TRANSFER_LENGTH);

/* per character: assemble your own frame on UART_EVENT_RX_CHAR */
if (p_args->event == UART_EVENT_RX_CHAR) {
    if (sizeof(buf) > index) buf[index++] = (uint8_t)p_args->data;   /* bound-check! */
}
```

Callback-driven code should set flags, not do work. Keep callbacks short.

### I2C master

```c
R_SCI_I2C_Open(&g_i2c_ctrl, &g_i2c_cfg);

/* register read: write the register address, then read */
R_SCI_I2C_Write(&g_i2c_ctrl, &reg, 1, true);
/* wait for I2C_MASTER_EVENT_TX_COMPLETE */
R_SCI_I2C_Read(&g_i2c_ctrl, data, len, false);
/* wait for I2C_MASTER_EVENT_RX_COMPLETE */
```

Give I2C loops **timeouts** — an unresponsive slave otherwise hangs forever. If a sensor has
an address-select pin, set it deliberately and use the matching address.

### RTC

```c
R_RTC_Open(&g_rtc_ctrl, &g_rtc_cfg);
R_RTC_ClockSourceSet(&g_rtc_ctrl);
R_RTC_CalendarTimeSet(&g_rtc_ctrl, &set_time);   /* REQUIRED at least once, or RTC never starts */
R_RTC_PeriodicIrqRateSet(&g_rtc_ctrl, RTC_PERIODIC_IRQ_SELECT_1_SECOND);
R_RTC_CalendarAlarmSet(&g_rtc_ctrl, &alarm);
```

Callback events: `RTC_EVENT_PERIODIC_IRQ`, `RTC_EVENT_ALARM_IRQ`.

**`rtc_time_t` is C `struct tm`**, so the classic traps apply:
`tm_year` = **years since 1900** (2025 → 125), `tm_mon` = **0–11**.

Clock source: LOCO (internal, **inaccurate**) vs sub-clock (external 32 kHz crystal, accurate).

### ADC

```c
R_ADC_Open(&g_adc_ctrl, &g_adc_cfg);
R_ADC_ScanCfg(&g_adc_ctrl, &g_adc_channel_cfg);

while (1) {
    R_ADC_ScanStart(&g_adc_ctrl);      /* single-scan mode: start every time */
    while (!scan_complete_flag) { }    /* set by the scan-end callback */
    R_ADC_Read(&g_adc_ctrl, ADC_CHANNEL_n, &raw);
    double volts = (double)raw / 4095.0 * 3.3;
}
```

Config: 12-bit, right-aligned, clear-after-read on, single-scan, software trigger.

**Self-test**: short the input to GND → near 0; to VREF → near full scale. Do this before
trusting any reading. A floating input sits mid-range and jitters, which is normal.

### GPIO and external IRQ

```c
R_IOPORT_PinWrite(&g_ioport_ctrl, BSP_IO_PORT_xx_PIN_yy, BSP_IO_LEVEL_HIGH);
R_IOPORT_PinRead(&g_ioport_ctrl, BSP_IO_PORT_xx_PIN_yy, &level);

R_ICU_ExternalIrqOpen(&g_external_irq_ctrl, &g_external_irq_cfg);
R_ICU_ExternalIrqEnable(&g_external_irq_ctrl);   /* Open alone does not arm it */
```

A button with a pull-up reads **low when pressed** — get the polarity from the schematic,
not from habit.

---

## Copy-paste traps

1. **Pin claimed twice** → one peripheral's `Open` fails mysteriously. Check for overlap.
2. **Duplicate channel** within one peripheral type → `Open` fails.
3. **e² studio config changed but code lacks `g_xxx`** → the configurator output was never
   regenerated. In the IDE this is "generate project content"; from the CLI it is the
   Smart Configurator / project generator step.
4. **`FSP_ERR_NOT_OPEN`** → `Open` before `Start`, always.
5. **Callback name mismatch** → the callback in the configurator must match an existing
   global function, otherwise you get a link error.
6. **No Chinese/non-ASCII in paths** — e² studio project paths and file names should be
   ASCII; non-ASCII paths cause obscure failures.
7. **Float printing** → `-u _printf_float`, and enough stack.
8. **Integer division truncation** — `a / b` where both are integers truncates. Cast before
   dividing when a fractional result matters (frequency maths, duty ratios).
9. **Counter wraparound** in capture/period maths — handle the `second < first` case by
   adding the period, or the measurement jumps once per wrap.
