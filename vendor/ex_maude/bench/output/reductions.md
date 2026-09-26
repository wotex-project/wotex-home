Benchmark

## Maude Reduce Benchmarks

Full round-trip time for term reduction including IPC overhead.


## System

Benchmark suite executing on the following system:

<table style="width: 1%">
  <tr>
    <th style="width: 1%; white-space: nowrap">Operating System</th>
    <td>macOS</td>
  </tr><tr>
    <th style="white-space: nowrap">CPU Information</th>
    <td style="white-space: nowrap">Apple M5 Pro</td>
  </tr><tr>
    <th style="white-space: nowrap">Number of Available Cores</th>
    <td style="white-space: nowrap">18</td>
  </tr><tr>
    <th style="white-space: nowrap">Available Memory</th>
    <td style="white-space: nowrap">48 GB</td>
  </tr><tr>
    <th style="white-space: nowrap">Elixir Version</th>
    <td style="white-space: nowrap">1.19.4</td>
  </tr><tr>
    <th style="white-space: nowrap">Erlang Version</th>
    <td style="white-space: nowrap">28.5</td>
  </tr>
</table>

## Configuration

Benchmark suite executing with the following configuration:

<table style="width: 1%">
  <tr>
    <th style="width: 1%">:time</th>
    <td style="white-space: nowrap">10 s</td>
  </tr><tr>
    <th>:parallel</th>
    <td style="white-space: nowrap">1</td>
  </tr><tr>
    <th>:warmup</th>
    <td style="white-space: nowrap">2 s</td>
  </tr>
</table>

## Statistics



Run Time

<table style="width: 1%">
  <tr>
    <th>Name</th>
    <th style="text-align: right">IPS</th>
    <th style="text-align: right">Average</th>
    <th style="text-align: right">Deviation</th>
    <th style="text-align: right">Median</th>
    <th style="text-align: right">99th&nbsp;%</th>
  </tr>

  <tr>
    <td style="white-space: nowrap">reduce bool</td>
    <td style="white-space: nowrap; text-align: right">42.03 K</td>
    <td style="white-space: nowrap; text-align: right">23.79 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;30.01%</td>
    <td style="white-space: nowrap; text-align: right">23.38 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">33.33 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">reduce simple</td>
    <td style="white-space: nowrap; text-align: right">40.33 K</td>
    <td style="white-space: nowrap; text-align: right">24.80 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;29.17%</td>
    <td style="white-space: nowrap; text-align: right">24.21 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">32.96 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">reduce medium</td>
    <td style="white-space: nowrap; text-align: right">38.11 K</td>
    <td style="white-space: nowrap; text-align: right">26.24 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;17.96%</td>
    <td style="white-space: nowrap; text-align: right">25.67 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">36.25 &micro;s</td>
  </tr>

</table>


Run Time Comparison

<table style="width: 1%">
  <tr>
    <th>Name</th>
    <th style="text-align: right">IPS</th>
    <th style="text-align: right">Slower</th>
  <tr>
    <td style="white-space: nowrap">reduce bool</td>
    <td style="white-space: nowrap;text-align: right">42.03 K</td>
    <td>&nbsp;</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">reduce simple</td>
    <td style="white-space: nowrap; text-align: right">40.33 K</td>
    <td style="white-space: nowrap; text-align: right">1.04x</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">reduce medium</td>
    <td style="white-space: nowrap; text-align: right">38.11 K</td>
    <td style="white-space: nowrap; text-align: right">1.1x</td>
  </tr>

</table>



Memory Usage

<table style="width: 1%">
  <tr>
    <th>Name</th>
    <th style="text-align: right">Average</th>
    <th style="text-align: right">Factor</th>
  </tr>
  <tr>
    <td style="white-space: nowrap">reduce bool</td>
    <td style="white-space: nowrap">1.78 KB</td>
    <td>&nbsp;</td>
  </tr>
    <tr>
    <td style="white-space: nowrap">reduce simple</td>
    <td style="white-space: nowrap">1.77 KB</td>
    <td>1.0x</td>
  </tr>
    <tr>
    <td style="white-space: nowrap">reduce medium</td>
    <td style="white-space: nowrap">1.79 KB</td>
    <td>1.0x</td>
  </tr>
</table>