A tiny & dead-simple jQuery plugin for sortable tables. Here's a basic [demo](http://dl.dropbox.com/u/780754/tablesort/index.html).

Maintainers Wanted
---

![](https://img.shields.io/badge/maintainers-wanted-red.svg)

I don't use this library much anymore and don't have time to maintain it solo.

If you are interested in helping me maintain this library, please let me know! [**Read more here &raquo;**](https://github.com/kylefox/jquery-tablesort/issues/32)

Your help would be greatly appreciated!

Install
---

Just add jQuery & the tablesort plugin to your page:

```html
<script src="http://code.jquery.com/jquery-latest.min.js"></script>
<script src="jquery.tablesort.js"></script>
```

(The plugin is also compatible with [Zepto.js](https://github.com/madrobby/zepto)).

It's also available via [npm](https://www.npmjs.com/package/jquery-tablesort)

`npm install jquery-tablesort`

and [bower](https://bower.io/)

`bower install jquery-tablesort`

Basic use
---

Call the appropriate method on the table you want to make sortable:

```javascript
$('table').tablesort();
```

The table will be sorted when the column headers are clicked.

To prevent a column from being sortable, just add the `no-sort` class:

```html
<th class="no-sort">Photo</th>
```

Your table should follow this general format:

> Note: If you have access to the table markup, it's better to wrap your table rows
in `<thead>` and `<tbody>` elements (see below), resulting in a slightly faster sort.
>
> If you can't use `<thead>`, the plugin will fall back by sorting all `<tr>` rows
that contain a `<td>` element using jQuery's `.has()` method (ie, the header row,
containing `<th>` elements, will remain at the top where it belongs).

```html
<table>
	<thead>
		<tr>
			<th></th>
			...
		</tr>
	</thead>
	<tbody>
		<tr>
			<td></td>
			...
		</tr>
	</tbody>
</table>
```

If you want some imageless arrows to indicate the sort, just add this to your CSS:

```css
th.sorted.ascending:after {
	content: "  \2191";
}

th.sorted.descending:after {
	content: " \2193";
}
```

How cells are sorted
---

At the moment cells are naively sorted using string comparison. By default, the `<td>`'s text is used, but you can easily override that by adding a `data-sort-value` attribute to the cell. For example to sort by a date while keeping the cell contents human-friendly, just add the timestamp as the `data-sort-value`:

```html
<td data-sort-value="1331110651437">March 7, 2012</td>
```

This allows you to sort your cells using your own criteria without having to write a custom sort function. It also keeps the plugin lightweight by not having to guess & parse dates.

Defining custom sort functions
---

If you have special requirements (or don't want to clutter your markup like the above example) you can easily hook in your own function that determines the sort value for a given cell.

Custom sort functions are attached to `<th>` elements using `data()` and are used to determine the sort value for all cells in that column:

```javascript
// Sort by dates in YYYY-MM-DD format
$('thead th.date').data('sortBy', function(th, td, tablesort) {
	return new Date(td.text());
});

// Sort hex values, ie: "FF0066":
$('thead th.hex').data('sortBy', function(th, td, tablesort) {
	return parseInt(td.text(), 16);
});

// Sort by an arbitrary object, ie: a Backbone model:
$('thead th.personID').data('sortBy', function(th, td, tablesort) {
	return App.People.get(td.text());
});
```

Sort functions are passed three parameters:

* the `<th>` being sorted on
* the `<td>` for which the current sort value is required
* the `tablesort` instance

Custom comparison functions
---

If you need to implement more advanced sorting logic, you can specify a comparison function with the `compare` setting. The function works the same way as the `compareFunction` accepted by [`Array.prototype.sort()`](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/sort):

```javascript
function compare(a, b) {
  if (a < b) {
    return -1;		// `a` is less than `b` by some ordering criterion
  }
  if (a > b) {
    return 1;			// `a` is greater than `b` by the ordering criterion
  }

  return 0;				// `a` is equal to `b`
}
```

Events
---

The following events are triggered on the `<table>` element being sorted, `'tablesort:start'` and `'tablesort:complete'`. The `event` and `tablesort` instance are passed as parameters:

```javascript
$('table').on('tablesort:start', function(event, tablesort) {
	console.log("Starting the sort...");
});

$('table').on('tablesort:complete', function(event, tablesort) {
	console.log("Sort finished!");
});
```

tablesort instances
---

A table's tablesort instance can be retrieved by querying the data object:

```javascript
$('table').tablesort(); 												// Make the table sortable.
var tablesort = $('table').data('tablesort'); 	// Get a reference to it's tablesort instance
```

Properties:

```javascript
tablesort.$table 			// The <table> being sorted.
tablesort.$th					// The <th> currently sorted by (null if unsorted).
tablesort.index				// The column index of tablesort.$th (or null).
tablesort.direction		// The direction of the current sort, either 'asc' or 'desc' (or null if unsorted).
tablesort.settings		// Settings for this instance (see below).
```

Methods:

```javascript
// Sorts by the specified column and, optionally, direction ('asc' or 'desc').
// If direction is omitted, the reverse of the current direction is used.
tablesort.sort(th, direction);

tablesort.destroy();
```

Default Sorting
---

It's possible to apply a default sort on page load using the `.sort()` method described above. Simply grab the tablesort instance and call `.sort()`, padding in the `<th>` element you want to sort by.

Assuming your markup is `<table class="sortable">` and the column to sort by default is `<th class="default-sort">` you would write:

```javascript
$(function() {
    $('table.sortable').tablesort().data('tablesort').sort($("th.default-sort"));
});
```

Settings
---

Here are the supported options and their default values:

```javascript
$.tablesort.defaults = {
	debug: $.tablesort.DEBUG,		// Outputs some basic debug info when true.
	asc: 'sorted ascending',		// CSS classes added to `<th>` elements on sort.
	desc: 'sorted descending',
	compare: function(a, b) {		// Function used to compare values when sorting.
		if (a > b) {
			return 1;
		} else if (a < b) {
			return -1;
		} else {
			return 0;
		}
	}
};
```

You can also change the global debug value which overrides the instance's settings:

```javascript
$.tablesort.DEBUG = false;
```

Alternatives
---

I don't use this plugin much any more — most of the fixes & improvements are provided by contributors.

If this plugin isn't meeting your needs and you don't want to submit a pull-request, here are some alternative table-sorting plugins.

* [Stupid jQuery Table Sort](https://github.com/joequery/Stupid-Table-Plugin)

_(Feel free to suggest more by [opening a new issue](https://github.com/kylefox/jquery-tablesort/issues/new))_

Contributing
---

As always, all suggestions, bug reports/fixes, and improvements are welcome.

Minify JavaScript with [Closure Compiler](http://closure-compiler.appspot.com/home) (default options)

Help with any of the following is particularly appreciated:

* Performance improvements
* Making the code as concise/efficient as possible
* Browser compatibility

Please fork and send pull requests, or [report an issue.](https://github.com/kylefox/jquery-tablesort/issues)

# License

jQuery tablesort is distributed under the MIT License.
Learn more at http://opensource.org/licenses/mit-license.php

Copyright (c) 2012 Kyle Fox

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
