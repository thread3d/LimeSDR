// limesdr_probe - independent receive check for a LimeSDR through SoapySDR
//
// This tool exists to answer one question without involving ogn-rf: does the radio deliver
// sane 8-bit I/Q at the OGN centre frequency, and at what gain? ogn-rf converts the LMS7002M
// CS16 stream into the 8-bit unsigned "128 == zero" layout that librtlsdr produces, and if the
// conversion scale or the gain is wrong the OGN demodulator silently sees a bad signal. Being
// able to look at the raw numbers on their own makes that easy to tell apart from a DSP problem.
//
// Usage:
//   limesdr_probe [-d serial] [-f Hz] [-r Hz] [-g dB] [-n samples] [-o file.u8] [-s sweep_list]
//
//   -d serial     pick a device by serial number (default: first LimeSDR found)
//   -f Hz         centre frequency (default 868300000, the European OGN centre)
//   -r Hz         sample rate (default 1000000)
//   -g dB         gain in dB, as SoapySDR reports it (default 30)
//   -n samples    how many complex samples to capture (default 1000000)
//   -o file       also write the 8-bit I/Q to a file (interleaved I,Q,I,Q...)
//   -s list       sweep gains, e.g. -s 10,20,30,40,50, and report per gain instead of one capture
//   -q            quieter: no per-second progress
//
// Build:  g++ -O2 -o limesdr_probe limesdr_probe.cc -lSoapySDR
//
// Exit status: 0 capture succeeded, 1 usage or device error, 2 capture produced no samples.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

#include <string>
#include <vector>

#include <SoapySDR/Device.hpp>
#include <SoapySDR/Formats.hpp>

// ---------------------------------------------------------------------------------------------
// Statistics for one capture
// ---------------------------------------------------------------------------------------------
struct Stats
{ double   MinI, MaxI, MinQ, MaxQ;      // raw int16 excursion, tells us where the 12 bits sit
   double   MeanI, MeanQ;                // DC offset
   double   Mean8, Sd8;                  // after conversion to 8-bit unsigned
   double   Min8, Max8;
   double   ClipLow, ClipHigh;           // fraction of converted values pinned at 0 / 255
   uint64_t Samples;
   int      Timeouts, Errors;
   int      Overflows;                   // SOAPY_SDR_OVERFLOW: samples were lost
   double   Elapsed;                     // [sec] wall time spent inside the streaming loop
   double   Rate;                        // [samples/sec] achieved

   Stats() { MinI=1e9; MaxI=-1e9; MinQ=1e9; MaxQ=-1e9; MeanI=MeanQ=0; Mean8=Sd8=0;
             Min8=1e9; Max8=-1e9; ClipLow=ClipHigh=0; Samples=0; Timeouts=0; Errors=0;
             Overflows=0; Elapsed=0; Rate=0; }
};

// Wall clock, for throughput measurement
static double now_sec(void)
{ struct timespec Ts; clock_gettime(CLOCK_MONOTONIC, &Ts);
  return Ts.tv_sec + 1e-9*Ts.tv_nsec; }

// ---------------------------------------------------------------------------------------------
// One capture at a fixed gain
// ---------------------------------------------------------------------------------------------
struct Capture
{ double GainDb; Stats St; double Mean8, Sd8, DcI, DcQ; };

static int doCapture(SoapySDR::Device *Dev, SoapySDR::Stream *Stream, size_t Mtu,
                     double GainDb, long SamplesWanted, int Shift, int Verbose, Stats &St)
{ // Manual gain: without this an AGC setting silently overrides every setGain() below, and the
  // whole sweep reads flat no matter what gain is asked for.
  Dev->setGainMode(SOAPY_SDR_RX, 0, false);
  Dev->setGain(SOAPY_SDR_RX, 0, GainDb);

  std::vector<int16_t> Buf(2*Mtu);
  void *Buffs[1]; Buffs[0]=&Buf[0];

  long Done=0; int Timeouts=0;
  double SumI=0, SumQ=0, NAcc=0, Sum8=0, SumSq8=0, ClipLow=0, ClipHigh=0;
  double Started=now_sec();

  while(Done<SamplesWanted)
  { size_t Want=Mtu; if((long)Want>SamplesWanted-Done) Want=SamplesWanted-Done;
    int Flags=0; long long TimeNs=0;
    int Ret=Dev->readStream(Stream, Buffs, Want, Flags, TimeNs, 500000);
    if(Ret==SOAPY_SDR_TIMEOUT) { if(++Timeouts>10) { fprintf(stderr,"timeout: no data\n"); St.Errors++; return -1; } continue; }
    if(Ret==SOAPY_SDR_OVERFLOW) { St.Overflows++; continue; }
    if(Ret<0) { fprintf(stderr,"readStream() => %d\n", Ret); St.Errors++; return -1; }
    Timeouts=0;

    for(int Idx=0; Idx<Ret; Idx++)
    { int16_t I=Buf[2*Idx+0], Q=Buf[2*Idx+1];
      if(I<St.MinI) St.MinI=I; if(I>St.MaxI) St.MaxI=I;
      if(Q<St.MinQ) St.MinQ=Q; if(Q>St.MaxQ) St.MaxQ=Q;
      SumI+=I; SumQ+=Q;

      int U8I=(I>>Shift)+128; if(U8I<0) U8I=0; if(U8I>255) U8I=255;
      int U8Q=(Q>>Shift)+128; if(U8Q<0) U8Q=0; if(U8Q>255) U8Q=255;
      if(U8I==0)   ClipLow++;  if(U8I==255) ClipHigh++;
      if(U8Q==0)   ClipLow++;  if(U8Q==255) ClipHigh++;
      if(U8I<St.Min8) St.Min8=U8I; if(U8I>St.Max8) St.Max8=U8I;
      if(U8Q<St.Min8) St.Min8=U8Q; if(U8Q>St.Max8) St.Max8=U8Q;

      double A=U8I-128.0, B=U8Q-128.0;
      Sum8 += 0.5*(A+B);
      SumSq8 += 0.5*(A*A+B*B); }

    Done+=Ret; St.Samples+=Ret; NAcc+=2.0*Ret;
    if(Verbose && (St.Samples % (1<<18) < (uint64_t)Ret))
      fprintf(stderr,"  %ld/%ld samples\r", Done, SamplesWanted); }

  St.Elapsed=now_sec()-Started;
  if(St.Elapsed>0) St.Rate=Done/St.Elapsed;
  if(NAcc>0)
  { St.MeanI=SumI/NAcc; St.MeanQ=SumQ/NAcc;
    St.Mean8=Sum8/NAcc; St.Sd8=sqrt(fabs(SumSq8/NAcc-St.Mean8*St.Mean8));
    St.ClipLow=ClipLow/NAcc; St.ClipHigh=ClipHigh/NAcc; }
  return 0; }

// ---------------------------------------------------------------------------------------------
// A gain sweep: find the setting that fills the 8-bit range without clipping
// ---------------------------------------------------------------------------------------------
static int doSweep(SoapySDR::Device *Dev, long SamplesWanted, int Shift,
                   const std::vector<double> &Gains)
{ printf("  gain [dB]   mean8    sd8    min8  max8   clip-low clip-high  raw-I[min..max]\n");
  for(size_t Idx=0; Idx<Gains.size(); Idx++)
  { SoapySDR::Stream *Stream=Dev->setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, std::vector<size_t>(1,0));
    size_t Mtu=Dev->getStreamMTU(Stream);
    Dev->activateStream(Stream);

    Stats St;
    if(doCapture(Dev, Stream, Mtu, Gains[Idx], SamplesWanted, Shift, 0, St)<0)
    { printf("  %8.1f   (capture failed)\n", Gains[Idx]); Dev->deactivateStream(Stream); Dev->closeStream(Stream); continue; }

    printf("  %8.1f  %6.2f %6.2f  %5.0f %5.0f   %7.3f%%  %8.3f%%  %6.0f..%.0f\n",
           Gains[Idx], St.Mean8, St.Sd8, St.Min8, St.Max8, 100*St.ClipLow, 100*St.ClipHigh,
           St.MinI, St.MaxI);

    Dev->deactivateStream(Stream); Dev->closeStream(Stream); }
  return 0; }

// ---------------------------------------------------------------------------------------------
int main(int argc, char **argv)
{ const char *Serial=0;
  double Freq=868300000.0, Rate=1000000.0, GainDb=30.0;
  long SamplesWanted=1000000;
  const char *OutFile=0;
  const char *Antenna=0;
  int AllAntennas=0;
  std::vector<double> Sweep;
  int Verbose=1, Shift=8, TestSignal=(-1);

  int Opt;
  while((Opt=getopt(argc, argv, "d:f:r:g:n:o:s:a:Athq"))!=-1)
  { switch(Opt)
    { case 'd': Serial=optarg; break;
      case 'f': Freq=atof(optarg); break;
      case 'r': Rate=atof(optarg); break;
      case 'g': GainDb=atof(optarg); break;
      case 'n': SamplesWanted=atol(optarg); break;
      case 'o': OutFile=optarg; break;
      case 'a': Antenna=optarg; break;
      case 'A': AllAntennas=1; break;
      case 's': { std::string List=optarg; size_t Pos=0;
                  while(Pos<List.size())
                  { size_t Comma=List.find(',', Pos);
                    if(Comma==std::string::npos) Comma=List.size();
                    Sweep.push_back(atof(List.substr(Pos, Comma-Pos).c_str()));
                    Pos=Comma+1; } }
                break;
      case 't': TestSignal=4; break;      // TSG_NCO: digital test tone, -1 to disable
      case 'q': Verbose=0; break;
      case 'h': default:
        printf("usage: %s [-d serial] [-f Hz] [-r Hz] [-g dB] [-n samples] [-o file.u8]\n"
               "          [-s gain,gain,...] [-a LNAL|LNAH|LNAW] [-A] [-t] [-q]\n"
               "  -s  sweep these gains, one capture each\n"
               "  -a  select an LNA path explicitly (default: chosen from the frequency)\n"
               "  -A  try every LNA path in turn (find out which connector the antenna is on)\n"
               "  -t  enable the LMS7002M TSG_NCO digital test signal (for scale calibration)\n", argv[0]);
        return 1; } }

  // ---------------------------------------------------------------------------------------
  // Find and open the device
  // ---------------------------------------------------------------------------------------
  SoapySDR::KwargsList List=SoapySDR::Device::enumerate("driver=lime");
  if(List.empty()) { fprintf(stderr,"no LimeSDR found\n"); return 1; }

  SoapySDR::Kwargs Kw; int Found=(-1);
  for(size_t Idx=0; Idx<List.size(); Idx++)
  { SoapySDR::Kwargs::const_iterator It=List[Idx].find("serial");
    if( (Serial==0) || ( (It!=List[Idx].end()) && (strcmp(It->second.c_str(), Serial)==0) ) )
    { Kw=List[Idx]; Found=(int)Idx; break; } }
  if(Found<0) { fprintf(stderr,"no LimeSDR with serial %s\n", Serial); return 1; }
  Kw["driver"]="lime";

  printf("device        : %s\n", Kw.count("label") ? Kw["label"].c_str() : "(unlabelled)");
  printf("serial        : %s\n", Kw.count("serial") ? Kw["serial"].c_str() : "(none)");
  printf("media         : %s\n", Kw.count("media") ? Kw["media"].c_str() : "(unknown)");

  SoapySDR::Device *Dev=0;
  try { Dev=SoapySDR::Device::make(Kw); }
  catch(const std::exception &Ex) { fprintf(stderr,"cannot open: %s\n", Ex.what()); return 1; }

  SoapySDR::Kwargs Hw=Dev->getHardwareInfo();
  printf("hardware      : ");
  for(SoapySDR::Kwargs::const_iterator It=Hw.begin(); It!=Hw.end(); ++It)
    printf("%s%s=%s", (It==Hw.begin())?"":"  ", It->first.c_str(), It->second.c_str());
  printf("\n");

  // Digital test signal, when asked for: this is how the CS16 scale gets pinned down.
  // A full-scale LMS7002M test tone must come back as either ~+-2047 (12-bit words) or
  // ~+-32767 (12 bits shifted into the top of a 16-bit word), and the two need different
  // right shifts to land on the 8-bit range ogn-rf expects.
  if(TestSignal>=0)
  { try { Dev->writeSetting("TSG_NCO", std::to_string(TestSignal));
          printf("test signal   : TSG_NCO=%d (digital test tone ON)\n", TestSignal); }
    catch(const std::exception &Ex) { fprintf(stderr,"cannot enable TSG_NCO: %s\n", Ex.what()); } }

  int Ret=0;
  try
  {
    Dev->setSampleRate(SOAPY_SDR_RX, 0, Rate);
    printf("sample rate   : %.0f Hz requested, %.3f Hz set\n", Rate, Dev->getSampleRate(SOAPY_SDR_RX,0));

    // Which LNA path (antenna connector) to use
    std::vector<std::string> Ants=Dev->listAntennas(SOAPY_SDR_RX,0);
    printf("antennas      :");
    for(size_t Idx=0; Idx<Ants.size(); Idx++) printf(" %s", Ants[Idx].c_str());
    printf("\n");

    const char *Want=Antenna;
    if(Want==0) Want=Freq<1500e6 ? "LNAL" : "LNAH";
    int Selected=0;
    if(Antenna || !AllAntennas)
      for(size_t Idx=0; Idx<Ants.size(); Idx++)
        if(Ants[Idx]==Want) { Dev->setAntenna(SOAPY_SDR_RX,0,Ants[Idx]); printf("antenna       : %s\n", Want); Selected=1; break; }
    if(!Selected && !AllAntennas) printf("antenna       : %s not offered by the driver, left as is\n", Want);


    Dev->setFrequency(SOAPY_SDR_RX, 0, Freq);
    printf("frequency     : %.0f Hz requested, %.0f Hz tuned\n", Freq, Dev->getFrequency(SOAPY_SDR_RX,0));

    SoapySDR::Range Range=Dev->getGainRange(SOAPY_SDR_RX,0);
    printf("gain range    : %.1f .. %.1f dB\n", Range.minimum(), Range.maximum());

    if(AllAntennas)
    { // Which connector is the antenna actually on? A path that is not connected shows only
      // leakage and sits ~20 dB below one that is, which is easy to see in sd8.
      printf("\nper-LNA-path capture at %.1f dB gain\n", GainDb);
      printf("  path    mean8    sd8    min8  max8   raw-I[min..max]\n");
      for(size_t Ant=0; Ant<Ants.size(); Ant++)
      { if(Ants[Ant]=="NONE") continue;
        Dev->setAntenna(SOAPY_SDR_RX,0,Ants[Ant]);
        SoapySDR::Stream *Stream=Dev->setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, std::vector<size_t>(1,0));
        if(Stream==0) { printf("  %-6s (no stream)\n", Ants[Ant].c_str()); continue; }
        size_t Mtu=Dev->getStreamMTU(Stream);
        Dev->activateStream(Stream);
        Stats St;
        if(doCapture(Dev, Stream, Mtu, GainDb, SamplesWanted, Shift, 0, St)<0)
        { printf("  %-6s (capture failed)\n", Ants[Ant].c_str()); }
        else
        { printf("  %-6s %6.2f %6.2f  %5.0f %5.0f  %6.0f..%.0f\n",
                 Ants[Ant].c_str(), St.Mean8, St.Sd8, St.Min8, St.Max8, St.MinI, St.MaxI); }
        Dev->deactivateStream(Stream); Dev->closeStream(Stream); }
    }
    else if(Sweep.empty())
    { SoapySDR::Stream *Stream=Dev->setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, std::vector<size_t>(1,0));
      if(Stream==0) { fprintf(stderr,"setupStream failed\n"); Ret=1; }
      else
      { size_t Mtu=Dev->getStreamMTU(Stream);
        Dev->activateStream(Stream);

        Stats St;
        if(doCapture(Dev, Stream, Mtu, GainDb, SamplesWanted, Shift, Verbose, St)<0) Ret=2;
        else
        { printf("\ncapture       : %llu complex samples at %.1f dB gain\n", (unsigned long long)St.Samples, GainDb);
          printf("raw int16     : I %6.0f..%-6.0f mean %7.1f   Q %6.0f..%-6.0f mean %7.1f\n",
                 St.MinI, St.MaxI, St.MeanI, St.MinQ, St.MaxQ, St.MeanQ);
          printf("8-bit (>>%d)   : mean %6.2f  sd %5.2f  min %3.0f  max %3.0f\n",
                 Shift, St.Mean8+128.0, St.Sd8, St.Min8, St.Max8);
          printf("clipping      : %.3f%% at 0, %.3f%% at 255\n", 100*St.ClipLow, 100*St.ClipHigh);
          printf("throughput    : %.3f s for %.3f s of signal  => %.0f samples/s (%.1f%% of real time)\n",
                 St.Elapsed, (double)St.Samples/Rate, St.Rate, 100.0*St.Rate/Rate);
          if(St.Overflows) printf("overflows     : %d (samples were lost by the driver)\n", St.Overflows);
          if(St.Samples==0) Ret=2;

          if(OutFile)
          { FILE *File=fopen(OutFile,"wb");
            if(File==0) { fprintf(stderr,"cannot write %s\n", OutFile); Ret=1; }
            else
            { // capture again straight to the file, so the file matches the stats above
              Dev->deactivateStream(Stream);
              Stream=Dev->setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, std::vector<size_t>(1,0));
              Mtu=Dev->getStreamMTU(Stream); Dev->activateStream(Stream);
              std::vector<int16_t> Buf(2*Mtu);
              void *Buffs[1]; Buffs[0]=&Buf[0];
              long Done=0;
              while(Done<SamplesWanted)
              { size_t Want=Mtu; if((long)Want>SamplesWanted-Done) Want=SamplesWanted-Done;
                int Flags=0; long long TimeNs=0;
                int Got=Dev->readStream(Stream, Buffs, Want, Flags, TimeNs, 500000);
                if(Got==SOAPY_SDR_TIMEOUT || Got==SOAPY_SDR_OVERFLOW) continue;
                if(Got<0) break;
                std::vector<uint8_t> Out(2*Got);
                for(int Idx=0; Idx<2*Got; Idx++)
                { int Val=(Buf[Idx]>>Shift)+128; if(Val<0) Val=0; if(Val>255) Val=255; Out[Idx]=(uint8_t)Val; }
                fwrite(&Out[0], 1, Out.size(), File);
                Done+=Got; }
              fclose(File);
              printf("output        : %s (%ld samples, interleaved 8-bit I/Q)\n", OutFile, Done); } }

          Dev->deactivateStream(Stream); }
        Dev->closeStream(Stream); } }
    else
    { printf("\ngain sweep over %ld samples each\n", SamplesWanted);
      doSweep(Dev, SamplesWanted, Shift, Sweep); }
  }
  catch(const std::exception &Ex)
  { fprintf(stderr,"device error: %s\n", Ex.what()); Ret=1; }

  SoapySDR::Device::unmake(Dev);
  return Ret; }
