Benchmark

# ExMaude Performance Benchmarks

Run on 2026-09-05 21:51:17.121604Z.
Values below measure this machine and process configuration.

## Parser Benchmarks (Pure Elixir, No Maude Required)


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
    <td style="white-space: nowrap">5 s</td>
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
    <td style="white-space: nowrap">parse_result</td>
    <td style="white-space: nowrap; text-align: right">1432.88 K</td>
    <td style="white-space: nowrap; text-align: right">0.70 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;1534.22%</td>
    <td style="white-space: nowrap; text-align: right">0.54 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">0.96 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_errors</td>
    <td style="white-space: nowrap; text-align: right">821.40 K</td>
    <td style="white-space: nowrap; text-align: right">1.22 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;1134.58%</td>
    <td style="white-space: nowrap; text-align: right">0.92 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">1.25 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_module_list</td>
    <td style="white-space: nowrap; text-align: right">678.62 K</td>
    <td style="white-space: nowrap; text-align: right">1.47 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;540.16%</td>
    <td style="white-space: nowrap; text-align: right">1.29 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">2.33 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_search_results</td>
    <td style="white-space: nowrap; text-align: right">144.26 K</td>
    <td style="white-space: nowrap; text-align: right">6.93 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;234.85%</td>
    <td style="white-space: nowrap; text-align: right">6.13 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">12.17 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_term</td>
    <td style="white-space: nowrap; text-align: right">93.89 K</td>
    <td style="white-space: nowrap; text-align: right">10.65 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;186.95%</td>
    <td style="white-space: nowrap; text-align: right">8.58 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">39.29 &micro;s</td>
  </tr>

</table>


Run Time Comparison

<table style="width: 1%">
  <tr>
    <th>Name</th>
    <th style="text-align: right">IPS</th>
    <th style="text-align: right">Slower</th>
  <tr>
    <td style="white-space: nowrap">parse_result</td>
    <td style="white-space: nowrap;text-align: right">1432.88 K</td>
    <td>&nbsp;</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_errors</td>
    <td style="white-space: nowrap; text-align: right">821.40 K</td>
    <td style="white-space: nowrap; text-align: right">1.74x</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_module_list</td>
    <td style="white-space: nowrap; text-align: right">678.62 K</td>
    <td style="white-space: nowrap; text-align: right">2.11x</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_search_results</td>
    <td style="white-space: nowrap; text-align: right">144.26 K</td>
    <td style="white-space: nowrap; text-align: right">9.93x</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">parse_term</td>
    <td style="white-space: nowrap; text-align: right">93.89 K</td>
    <td style="white-space: nowrap; text-align: right">15.26x</td>
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
    <td style="white-space: nowrap">parse_result</td>
    <td style="white-space: nowrap">0.63 KB</td>
    <td>&nbsp;</td>
  </tr>
    <tr>
    <td style="white-space: nowrap">parse_errors</td>
    <td style="white-space: nowrap">0.91 KB</td>
    <td>1.43x</td>
  </tr>
    <tr>
    <td style="white-space: nowrap">parse_module_list</td>
    <td style="white-space: nowrap">2.18 KB</td>
    <td>3.44x</td>
  </tr>
    <tr>
    <td style="white-space: nowrap">parse_search_results</td>
    <td style="white-space: nowrap">4.73 KB</td>
    <td>7.47x</td>
  </tr>
    <tr>
    <td style="white-space: nowrap">parse_term</td>
    <td style="white-space: nowrap">8.73 KB</td>
    <td>13.8x</td>
  </tr>
</table>