#include <avr/wdt.h>
#include <avr/sleep.h>
#include <RF12.h>

// Node Idenfier for the RFM12B (2-30)
const unsigned char _rfNodeId = 2; 
// RFM12B band RF12_433MHZ, RF12_868MHZ, RF12_915MHZ
const unsigned char _rfBand = RF12_915MHZ;
// How long to sleep between probe measurments, in seconds
const unsigned char _sleepInterval = 10; 
// Analog pins to read, this is a bitfild. LSB is analog 0
const unsigned char _enabledProbePins = 0xff;  
// Analog pin connected to source power.  Set to 0xff to disable sampling
const unsigned char _pinBattery = 1;
// Digital pins for LEDs
const unsigned char _pinLedRx = 4;
const unsigned char _pinLedTx = 5;

#define RF_PINS_PER_SOURCE 4 

typedef struct tagRf12ProbeUpdateHdr 
{
  unsigned char seqNo;
  unsigned int batteryLevel;
} rf12_probe_update_hdr_t;

typedef struct tagRf12ProbeUpdate 
{
  unsigned char probeIdx: 6;
  unsigned int adcValue: 10;
} rf12_probe_update_t;

static unsigned int _previousReads[RF_PINS_PER_SOURCE];
static unsigned char _sameCount;
static unsigned char _seqNo;

ISR(WDT_vect) {
  // The WDT is used solely to wake us from sleep
  wdt_disable();
}

void sleep(uint8_t wdt_period) {
  set_sleep_mode(SLEEP_MODE_PWR_DOWN);

  // Disable ADC, still needs to be shutdown via PRR
  ADCSRA &= ~bit(ADEN);

  // TODO: Figure out what else I can safely disable
  // Disable analog comparator to
  // Internal Voltage Reference? 
  //   When turned on again, the user must allow the reference to start up before the output is used. 
  //   these should be disabled at all times, not just sleep
  
  // Set the watchdog to wake us up and turn on its interrupt
  wdt_enable(wdt_period);
  WDTCSR |= bit(WDIE);

  // Turn off Brown Out Detector
  // sleep must be entered within 3 cycles of BODS being set
  sleep_enable();
  MCUCR = MCUCR | bit(BODSE) | bit(BODS);
  MCUCR = MCUCR & ~bit(BODSE) | bit(BODS);
  
  // Sleep
  sleep_cpu();
  
  // Back from sleep
  sleep_disable();
  ADCSRA |= bit(ADEN);
}

void sleepSeconds(unsigned char secs)
{
  while (secs >= 8) { sleep(WDTO_8S);  secs -=8; }
  if (secs >= 4) { sleep(WDTO_4S);  secs -= 4; }
  if (secs >= 2) { sleep(WDTO_2S);  secs -= 2; }
  if (secs >= 1) { sleep(WDTO_1S); }
}

void rf12_doWork(void)
{
  if (rf12_recvDone() && rf12_crc == 0)
  {
    digitalWrite(_pinLedRx, HIGH);
    sleep(WDTO_120MS);  // temp placeholder code
  }
  else
    digitalWrite(_pinLedRx, LOW);
}

void transmitTemps(unsigned char txCount)
{
  char outbuf[
    sizeof(rf12_probe_update_hdr_t) + 
    RF_PINS_PER_SOURCE * sizeof(rf12_probe_update_t)
  ];
  rf12_probe_update_hdr_t *hdr;

  hdr = (rf12_probe_update_hdr_t *)outbuf;
  hdr->seqNo = _seqNo++;
  if (_pinBattery != 0xff)
    hdr->batteryLevel = (unsigned long)analogRead(_pinBattery) * 3300L / 1023;
  else
    hdr->batteryLevel = 3300;

  // Send all values regardless of if they've changed or not
  rf12_probe_update_t *up = (rf12_probe_update_t *)&hdr[1];
  for (unsigned char pin=0; pin < RF_PINS_PER_SOURCE; ++pin)
  {
    // If the pin is not enabled, skip it
    if ((_enabledProbePins & (1 << pin)) == 0)
      continue;
    up->probeIdx = pin;
    up->adcValue = _previousReads[pin];
    ++up;
  }

  // Hacky way to determine how much to send is see where our buffer pointer 
  // compared to from the start of the buffer
  unsigned char len = (unsigned int)up - (unsigned int)outbuf;

  digitalWrite(_pinLedTx, HIGH);
  rf12_sleep(RF12_WAKEUP);
  
  while (txCount--)
  {
    while (!rf12_canSend())
      rf12_doWork();
  
    // HDR is set to 0 so broadcast, no ACK requested
    rf12_sendStart(0, outbuf, len);
    rf12_sendWait(1);
  }  /* while txCount */ 
  
  rf12_sleep(RF12_SLEEP);
  digitalWrite(_pinLedTx, LOW);
}

inline void newTempsAvailable(void)
{
  transmitTemps(1);
}

void checkTemps(void)
{
  boolean modified = false;
  for (unsigned char pin=0; pin < RF_PINS_PER_SOURCE; ++pin)
  {
    // If the pin is not enabled, skip it
    if ((_enabledProbePins & (1 << pin)) == 0)
      continue;
      
    unsigned int newRead = analogRead(pin);
    if (newRead != _previousReads[pin])
      modified = true;
    _previousReads[pin] = newRead;
  }

  if (modified || (_sameCount > (60 / _sleepInterval)))
  {
    _sameCount = 0;
    newTempsAvailable();
  }
  else
    ++_sameCount;
}

void setup(void)
{
  //Serial.begin(115200);  
  rf12_initialize(_rfNodeId, _rfBand);

  pinMode(_pinLedRx, OUTPUT);
  pinMode(_pinLedTx, OUTPUT);

  // Turn off the units we never use (this only affects non-sleep power
  PRR = bit(PRUSART0) | bit(PRTWI) | bit(PRTIM1) | bit(PRTIM2);
  // Disable digital input buffers on the analog in ports
  DIDR0 = bit(ADC5D) | bit(ADC4D) | bit(ADC3D) | bit(ADC2D) | bit(ADC1D) | bit(ADC0D);
  DIDR1 = bit(AIN1D) | bit(AIN0D);

  // Force a reading and transmit multiple times so the master can sync its seqno
  memset(_previousReads, 0xff, sizeof(_previousReads));
  checkTemps();
  transmitTemps(2);
}

void loop(void)
{
  rf12_doWork();
  checkTemps();
  sleepSeconds(_sleepInterval);
}

