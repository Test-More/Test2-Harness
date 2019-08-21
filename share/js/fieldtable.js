// var table = field_table(
//  class => TableClass,
//  id => ID (for wrapper)
//
//  fetch => URL_FOR_ITEMS,
//
//  place_row => function(row_html, item, table) { return bool } // true means function placed row, false means append row
//  modify_row_hook => function(row_html, item) { return null },
//
//  row_redraw_check => function(item) { return bool },
//  row_redraw_fetch => function(item) { return uri },
//  row_redraw_interval => integer,
//
//  dynamic_field_attribute => FIELD_NAME,
//  dynamic_field_fetch  => function(field_data) { return uri },
//
//  columns => [
//      { field: '', label: '', sortable: BOOL, class: '', builder => function(item, col, field_spec) { ... }},
//      ...
//  ],
//
//  postfix_columns => [
//      ...
//  ],
// )

function FieldTable(spec) {
    var me = this;
    me.spec = spec;
    me.rows = [];
    me.columns = [];
    me.postfix_columns = [];
    me.dynamic_columns = [];
    me.dynamic_column_lookup = {};
    me.redraw = {};
    me.redraw_id = 1;

    me.render = function() {
        me.table = $('<table class="field-table ' + spec.class + '"></table>');
        me.header = me.render_header();
        me.table.append(me.header);

        if (me.spec.row_redraw_interval) {
            setInterval(function() {
                Object.keys(me.redraw).forEach(function (redraw_id) {
                    var old = me.redraw[redraw_id];
                    delete me.redraw[redraw_id];

                    var uri = me.spec.row_redraw_fetch(old.item);
                    $.ajax(uri, {
                        'data': { 'content-type': 'application/json' },
                        'error': function(a, b, c) { me.redraw[redraw_id] = old },
                        'success': function(item) {
                            var row = me.render_row(item);
                            row.index = old.index;

                            if (me.spec.modify_row_hook) {
                                me.spec.modify_row_hook(row.html, item);
                            }

                            if (me.spec.row_redraw_check(item)) {
                                me.redraw[row.redraw_id] = row;
                            }

                            me.rows[old.index] = row;
                            old.html.replaceWith(row.html);
                            old.html.remove();
                        },
                    });
                });
            }, me.spec.row_redraw_interval);
        }

        if (typeof(me.spec.fetch) === 'string') {
            t2hui.fetch(me.spec.fetch, {}, me.render_item);
        }
        else if (typeof(me.spec.fetch) === 'object') {
            me.spec.fetch.forEach(me.render_item);
        }

        var wrapper = $('<div id="' + spec.id + '" class="field-table-wrapper ' + spec.class + '"></div>');
        wrapper.append(me.table);
        return wrapper;

    }

    me.render_item = function(item) {
        var row = me.render_row(item);

        if (me.spec.modify_row_hook) {
            me.spec.modify_row_hook(row.html, item);
        }

        if (me.spec.place_row) {
            if (!me.spec.place_row(row.html, item, table)) {
                me.table.append(row.html);
            }
        }
        else {
            me.table.append(row.html);
        }

        if (me.spec.row_redraw_check) {
            if (me.spec.row_redraw_check(item)) {
                row.redraw_id = me.redraw_id++;
                me.redraw[row.redraw_id] = row;
            }
        }

        row.index = me.rows.length;
        me.rows.push(row);
    }

    me.render_row = function(item) {
        var row = {
            'html': $('<tr></tr>'),
            'columns': [],
            'dynamic_columns': [],
            'postfix_columns': [],
            'item': item,
        };

        me.spec.columns.forEach(function(data) {
            var col = me.render_row_col(data, item);
            row.html.append(col);
            row.columns.push(col);
        });

        me.dynamic_columns.forEach(function() {
            var col = $('<td></td>');
            row.html.append(col);
            row.dynamic_columns.push(col);
        });

        me.spec.postfix_columns.forEach(function(data) {
            var col = me.render_row_col(data, item);
            row.html.append(col);
            row.postfix_columns.push(col);
        });

        var attr = me.spec.dynamic_field_attribute;
        if (attr && item[attr]) {
            item[attr].forEach(function(field) {
                var col = me.render_dynamic_col(field);

                var idx = me.find_dynamic_column(field.name);
                if (idx === null) {
                    idx = me.inject_dynamic_column({"sortable": true, "name": field.name});
                    if (row.dynamic_columns.length) {
                        row.dynamic_columns[row.dynamic_columns.length - 1].after(col);
                    }
                    else if (row.columns.length) {
                        row.columns[row.columns.length - 1].after(col);
                    }
                    else {
                        row.prepend(col);
                    }

                    row.dynamic_columns.push(col);
                }
                else {
                    row.dynamic_columns[idx].replaceWith(col);
                    row.dynamic_columns[idx] = col;
                }
            })
        }

        return row;
    }

    me.render_dynamic_col = function(field) {
        var col = $('<td>' + field.details + '</td>');

        if (field.data) {
            var viewer = $('<div class="tool etoggle" title="Extended Data"><i class="far fa-list-alt"></i></div>');
            col.prepend(viewer);
            viewer.click(function() {
                $('#modal_body').empty();
                $('#modal_body').text("loading...");
                $('#free_modal').slideDown();

                var uri = me.spec.dynamic_field_fetch(field);

                $.ajax(uri, {
                    'data': { 'content-type': 'application/json' },
                    'success': function(field) {
                        $('#modal_body').empty();
                        $('#modal_body').jsonView(field.data, {collapsed: true});
                    },
                });
            });
        }

        if (field.link) {
            var link = $('<a class="tool etoggle" title="Link" href="' + field.link + '"><i class="fas fa-external-link-alt"></i></a>');
            col.prepend(link);
        }

        return col;
    }

    me.render_row_col = function(data, item) {
        var col = $('<td class="' + data.class + '"></td>');

        if (data.builder) {
            data.builder(item, col, data);
        }
        else {
            col.text(item[data.name]);
        }

        return col;
    }

    me.render_header = function() {
        var header = $('<tr class="field-table-header"></tr>');

        me.spec.columns.forEach(function(data) {
            var col = me.render_header_col(data);
            header.append(col);
            me.columns.push(col);
        });

        me.spec.postfix_columns.forEach(function(data) {
            var col = me.render_header_col(data);
            header.append(col);
            me.postfix_columns.push(col);
        });

        return header;
    }

    me.render_header_col = function(data) {
        var label = data.label ? data.label : data.name;
        var col = $('<th class="field-table-header-col ' + data.class + '">' + label + '</th>');
        if (data.sortable) {
            col.addClass('sortable');
        }
        return col;
    }

    me.find_dynamic_column = function(field) {
        if (me.dynamic_column_lookup[field] !== null && me.dynamic_column_lookup[field] !== undefined) {
            return me.dynamic_column_lookup[field];
        }

        return null;
    }

    me.inject_dynamic_column = function(data) {
        var col = me.render_header_col(data);

        if (me.dynamic_columns.length) {
            me.dynamic_columns[me.dynamic_columns.length - 1].after(col);

            me.rows.forEach(function(row) {
                var td = $('<td></td>');
                row.dynamic_columns[row.dynamic_columns.length - 1].after(td);
                row.dynamic_columns.push(td);
            });
        }
        else if (me.columns.length) {
            me.columns[me.columns.length - 1].after(col);

            me.rows.forEach(function(row) {
                var td = $('<td></td>');
                row.columns[row.columns.length - 1].after(td);
                row.dynamic_columns.push(td);
            });
        }
        else {
            me.header.prepend(col);

            var row;
            me.rows.forEach(function(row) {
                var td = $('<td></td>');
                row.append(td);
                row.dynamic_columns.push(td);
            });
        }

        me.dynamic_column_lookup[data.name] = me.dynamic_columns.length;
        me.dynamic_columns.push(col);

        return me.dynamic_column_lookup[data.name];
    }

    return me;
}
