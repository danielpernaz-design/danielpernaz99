#!/usr/bin/env python3

import os
import sys
import time
import shutil
import logging

try:
    import serial
    from prompt_toolkit.shortcuts import button_dialog
except ModuleNotFoundError:
    # pyserial / prompt_toolkit may only be installed for python3.9 on
    # the MFG stations - re-run under it if this interpreter lacks them.
    _alt = shutil.which("python3.9")
    if _alt and os.path.realpath(_alt) != os.path.realpath(sys.executable):
        os.execv(_alt, [_alt] + sys.argv)
    raise

RESET = "\033[0m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
MAGENTA = "\033[35m"
CYAN = "\033[36m"
BOLD = "\033[1m"

# /tmp/wizard-nebula-enc-{time.strftime('%Y%m%d_%H%M%S')}.log

logging.basicConfig(
    level=logging.INFO,format="%(asctime)s %(levelname)s: %(message)s",
    handlers=[logging.FileHandler("/tmp/wizard-nebula-enc.log"),
    logging.StreamHandler(sys.stdout)], force=True
)
logger = logging.getLogger(__name__)


ser = serial.Serial()
ser.baudrate = 115200
ser.port = '/dev/ttyUSB0'
ser.timeout = 1

# Serial CLI credentials - only the new SES version asks for them.
# Old SES versions drop straight into the CLI without a login prompt.
USERNAME = "admin"
DEFAULT_PASSWORD = "cl$ses@!123"
NEW_PASSWORD = "Sescli@123"

# How long to watch the serial line for a login prompt before assuming
# the enclosure runs the old SES version (no authentication).
LOGIN_DETECT_TIMEOUT = 6
# How long the full login / password-change dialog may take once a
# login prompt has been seen.
LOGIN_TIMEOUT = 60

# Password that worked on the last login, so the next reconnect tries
# the right one first (the port is reopened for every operation).
active_password = DEFAULT_PASSWORD


def serial_login():
    """Authenticate on the serial CLI if the enclosure asks for it.

    New SES versions show a "CLI Login:" prompt and force a change of the
    default 'admin' password on the first login. Old SES versions never
    ask, in which case this function detects the regular ESM prompt (or
    times out quietly) and the wizard continues exactly as before.
    """
    global active_password

    ser.reset_input_buffer()
    ser.write(b'\r')

    buffer = ""
    login_seen = False
    password_sent = False
    quiet_reads = 0
    detect_deadline = time.time() + LOGIN_DETECT_TIMEOUT
    login_deadline = time.time() + LOGIN_TIMEOUT

    while time.time() < (login_deadline if login_seen else detect_deadline):
        chunk = ser.read(4096).decode(errors="ignore")
        if not chunk:
            if not login_seen:
                ser.write(b'\r')
                continue
            quiet_reads += 1
            if password_sent:
                # The line went quiet after the password with no new
                # prompt and no error - the CLI accepted it.
                if quiet_reads >= 2:
                    logger.info(f"{GREEN}Serial login successful.{RESET}")
                    return
            elif quiet_reads >= 3:
                # Stuck mid-login with nothing arriving - nudge the CLI
                # so it shows its current prompt again.
                ser.write(b'\r')
                quiet_reads = 0
            continue

        quiet_reads = 0
        buffer += chunk
        chunk_l = chunk.lower()

        if password_sent and ("incorrect" in chunk_l or "invalid" in chunk_l
                              or "denied" in chunk_l or "failed" in chunk_l):
            # Wrong password - switch to the other known one. Do not
            # discard the chunk: it usually already carries the next
            # "Login:" prompt, which is handled right below.
            logger.warning(f"{YELLOW}Login failed, retrying with the other known password...{RESET}")
            active_password = NEW_PASSWORD if active_password == DEFAULT_PASSWORD else DEFAULT_PASSWORD
            password_sent = False

        tail = buffer.rstrip()
        last_line = tail.splitlines()[-1] if tail else ""

        if last_line.endswith("Login:"):
            if password_sent:
                # Login prompt again right after a password means it was
                # rejected even if no error text was recognized.
                logger.warning(f"{YELLOW}Password rejected, retrying with the other known password...{RESET}")
                active_password = NEW_PASSWORD if active_password == DEFAULT_PASSWORD else DEFAULT_PASSWORD
            login_seen = True
            password_sent = False
            login_deadline = time.time() + LOGIN_TIMEOUT
            logger.info(f"{YELLOW}Login prompt detected (new SES version), logging in as '{USERNAME}'...{RESET}")
            ser.write(f"{USERNAME}\r".encode("ascii"))
            buffer = ""

        elif last_line.endswith("Password:"):
            login_seen = True
            if "New" in last_line:
                # Forced change of the default password on first login.
                logger.info(f"{YELLOW}Password change requested, setting the new password...{RESET}")
                ser.write(f"{NEW_PASSWORD}\r".encode("ascii"))
                active_password = NEW_PASSWORD
            elif "Confirm" in last_line or "Retype" in last_line or "again" in last_line:
                ser.write(f"{NEW_PASSWORD}\r".encode("ascii"))
            else:
                ser.write(f"{active_password}\r".encode("ascii"))
            password_sent = True
            buffer = ""

        elif not login_seen and ("ESM" in buffer or last_line.endswith((">", "#"))):
            # Regular CLI prompt without any login - old SES version.
            return

    if login_seen:
        logger.warning(f"{YELLOW}Login dialog did not finish in time, continuing anyway...{RESET}")


def open_serial():
    """Open the serial port and log in if the SES version requires it."""
    ser.open()
    serial_login()


def set_enc_id(id):
    try:
        open_serial()
        ser.write(b'fru set -encl\r')

    except serial.SerialException as e:
           logger.error("Serial error:", e)
           exit(2)
    is_fru = b""
    logger.info("Please wait...")
    while True:
        is_fru = ser.read(4096)
        is_fru_str = is_fru.decode(errors="ignore")


        if "FRU Name" in is_fru_str:
            logger.info(f"{YELLOW}Setting enclosure ID={id}, please wait...{RESET}")
            ser.write(f"Enclosure-{id}\r".encode("ascii"))
            break
        time.sleep(0.5)
        ser.write(b'\r')

    is_prompt =b""
    while True:
        try:
            is_prompt = ser.read(4096)
        except serial.SerialException as e:
            logger.error(f"{RED}{BOLD}Serial error: {RESET}", e)
            break
        if not is_prompt:
            continue

        is_prompt_str = is_prompt.decode(errors="ignore")
        if "ESM" in is_prompt_str:
            break
        time.sleep(0.5)
        ser.write(b'\r')
    ser.close()
    canister_reset()

def canister_reset():
    open_serial()
    ser.write(b'reset 0\r')
    logger.info("Performing canister reset...")
    time.sleep(15)

    ser.write(b'reset 3\r')
    logger.info("Performing peer canister reset...")
    time.sleep(10)
    logger.info(f"{GREEN}{BOLD}Enclosure ID is set{RESET}")
    ser.close()

def verify_enc_id(enc_id):
    try:
        open_serial()
        ser.write(b'fru get\r')
        time.sleep(1)
        fru_get_output = ser.read(8192).decode()

    except serial.SerialException as e:
           logger.error("Serial error:", e)
           exit(2)
    if f"FRU Name: Enclosure-{enc_id}" in fru_get_output:
        ser.close()
        return True
    ser.close()
    return False

def configure_enc():
    enc_id = 0
    if current_step == 1:
        enc_id = 1
    elif current_step == 2:
        enc_id = 2
    else:
        return

    logger.info(f"{YELLOW}Checking ENC-{enc_id} ID...{RESET}")
    if verify_enc_id(enc_id):
        operation_result = f"Enclosure ID is already set to {enc_id}!"
        logger.info(f"{CYAN}{BOLD}{operation_result}{RESET}")
        step["text"] = operation_result
        step["buttons"] = [("Back", "back"), ("Skip", "skip"), ("Exit", "exit")]
        return "continue"

    else:
        set_enc_id(enc_id)
        verify_enc_id(enc_id)
        time.sleep(2)
        operation_result = f"ENC-{enc_id} configured successfully."
        logger.info(f"{GREEN}{BOLD}{operation_result}{RESET}")
        step["text"] = operation_result

def main():
    global step
    global steps
    global current_step

    steps = [
        {
            "title": "Nebula ENC ID Wizard",
            "text": "Welcome to Nebula ENC ID Wizard!\nPlease connect USB-C cable to one of the two ESMs in the Nebula enclosure\nChoose an option to continue.",
            "buttons": [("Next", "next"), ("Skip", "skip"), ("Exit", "exit")]
        },
        {
            "title": "Configure ENC-1",
            "text": "Configure ENC-1, make sure the Serial cable is connected\nChoose an option to continue.",
            "buttons": [("Next", "next"), ("Back", "back"), ("Skip", "skip"), ("Exit", "exit")]
        },
        {
            "title": "Configure ENC-2",
            "text": "Configure ENC-2, make sure the Serial cable is connected\nChoose an option to continue.",
            "buttons": [("Next", "next"), ("Back", "back"), ("Skip", "skip"), ("Exit", "exit")]
        },
        {
            "title": "Finish",
            "text": "Wizard completed! confirm or go back.",
            "buttons": [("Confirm", "confirm"), ("Back", "back"), ("Exit", "exit")]
        }
    ]
    current_step = 0
    skip_next = False
    while True:
        step = steps[current_step]
        if skip_next:
            skip_next = False
            if current_step >= len(steps):
                logger.info(f"{GREEN}{BOLD} Wizard completed!{RESET}")
                break
            continue

        action = button_dialog(
            title=step["title"],
            text=step["text"],
            buttons=step["buttons"]
        ).run()

        if action == "next":
            if configure_enc() == "continue":
                continue
            current_step += 1
        elif action == "back":
            current_step -= 1
        elif action == "skip":
            skip_next = True
            current_step += 1
        elif action in ["finish", "confirm"]:
            logger.info(f"{GREEN}{BOLD}Wizard completed!{RESET}")
            break
        else:
            logger.error(f"{RED}{BOLD}Wizard exited.{RESET}")
            break

        if current_step < 0:
            current_step = 0
        if current_step >= len(steps):
            logger.info(f"{GREEN}{BOLD}Wizard completed!{RESET}")
            break

if __name__ == "__main__":
    main()
