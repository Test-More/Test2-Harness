$(function() {
    $('input#project').change(function() {
        var me = $(this);

        var versions = $("datalist#versions");
        versions.empty();
        t2hui.fetch(base_uri + 'query/versions/' + me.val(), {}, function(item) {
            var n = $('<option value="' + item + '"></option>');
            versions.append(n);
        });

        var categorys = $("datalist#categories");
        categorys.empty();
        t2hui.fetch(base_uri + 'query/categories/' + me.val(), {}, function(item) {
            var n = $('<option value="' + item + '"></option>');
            categorys.append(n);
        });

        var tiers = $("datalist#tiers");
        tiers.empty();
        t2hui.fetch(base_uri + 'query/tiers/' + me.val(), {}, function(item) {
            var n = $('<option value="' + item + '"></option>');
            tiers.append(n);
        });
    });
});
