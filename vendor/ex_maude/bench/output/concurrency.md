Benchmark

## Concurrency Benchmarks

Compares task scheduling and pool checkout overhead for five short reductions.
Results depend on the workload, pool size, and available CPU cores.


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
    <td style="white-space: nowrap">parallel 5 reduces</td>
    <td style="white-space: nowrap; text-align: right">8.90 K</td>
    <td style="white-space: nowrap; text-align: right">112.33 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;13.04%</td>
    <td style="white-space: nowrap; text-align: right">110.17 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">153.96 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">sequential 5 reduces</td>
    <td style="white-space: nowrap; text-align: right">7.90 K</td>
    <td style="white-space: nowrap; text-align: right">126.59 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;7.44%</td>
    <td style="white-space: nowrap; text-align: right">126.54 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">153.16 &micro;s</td>
  </tr>

</table>


Run Time Comparison

<table style="width: 1%">
  <tr>
    <th>Name</th>
    <th style="text-align: right">IPS</th>
    <th style="text-align: right">Slower</th>
  <tr>
    <td style="white-space: nowrap">parallel 5 reduces</td>
    <td style="white-space: nowrap;text-align: right">8.90 K</td>
    <td>&nbsp;</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">sequential 5 reduces</td>
    <td style="white-space: nowrap; text-align: right">7.90 K</td>
    <td style="white-space: nowrap; text-align: right">1.13x</td>
  </tr>

</table>