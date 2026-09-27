{ pkgs, ... }:
# --- CPU COOLING, AND WHY IT IS DRIVEN OVER USB RATHER THAN FROM THE BIOS ---
#
# WHAT IS IN THE MACHINE, identified 2026-09-27 from the USB tree (1b1c:0c20) and
# confirmed by liquidctl: a Corsair Hydro **H100i Pro XT**, a 240 mm AIO of roughly
# 2020 vintage, cooling a Ryzen 9 7900 whose PBO limit was raised from the stock 88 W
# to 142 W the same morning.
#
# It copes rather than struggles - measured under a full 24-thread load: Tctl 83.5 C,
# Tccd1 83.8 C, Tccd2 80.2 C, against a 95 C Tjmax. Eleven degrees spare and no
# throttling. But rejecting 142 W through 240 mm of radiator takes real airflow, which
# is the noise JL complained about. He did not make the machine loud by picking the
# Standard fan profile; he made it loud by giving the cooler 60 % more heat to move.
#
# WHY LIQUIDCTL AND NOT THE MOTHERBOARD'S SUPER I/O. Linux has NO fan control on this
# board today: every hwmon reports pwm=0, and the only fan tachometer visible is
# asus_ec_sensors' CPU_Opt, reading 0 RPM on an empty header. The Nuvoton chip is
# claimed by ACPI and `nct6775` cannot bind while acpi_enforce_resources is strict.
#
# Unlocking it means acpi_enforce_resources=lax, which lets the driver touch I/O ports
# ACPI also declares - the BIOS and the kernel then both write the same chip, and if a
# control daemon dies the fans hold their last value. On a machine that has already
# lost one drive to heat, that failure mode is not worth the convenience.
#
# The AIO is a USB device, so none of that applies. Nothing contends for a port, and
# the BIOS keeps owning the chassis fans as a safe fallback.
#
# AND THE SOURCE IS BETTER, which is the real argument. Every fan on this board is
# currently driven by CPU temperature, and CPU temperature on Zen 4 is violently
# unstable - sampled twice a second under a STEADY load, Tctl swung 69.6 -> 78.0 C in
# six seconds while the motherboard sensor sat at exactly 38.0 C throughout. Fans told
# to chase that surge constantly, and no curve fixes it because the input itself is
# the noise. Coolant temperature cannot behave that way: the liquid has thermal mass.
#
# OPEN QUESTION, to answer after the first boot with these rules active:
#     liquidctl status
# If it reports fan RPMs, the fans are wired to the pump unit and a coolant-temperature
# curve can be declared here as a systemd service:
#     liquidctl set fan speed 25 20  30 30  35 60  40 100
# If it reports only pump and liquid temperature, the fans are on the motherboard's
# CPU_FAN header and stay a BIOS matter - in which case the curve lives in Q-Fan and
# the win is limited to reading the coolant temperature.
#
# The package alone cannot talk to the device: liquidctl ships the udev rules that
# grant the console user access to the HID, and without services.udev.packages every
# invocation fails with "could not open, possibly due to insufficient permissions".
{
  environment.systemPackages = [ pkgs.liquidctl ];
  services.udev.packages = [ pkgs.liquidctl ];
}
