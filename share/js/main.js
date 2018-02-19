var t2hui = {};

$(function() {
    $("div.expander").each(function() { t2hui.apply_expander($(this)) });

    $("div.json-view").each(function() {
        var div = $(this);
        var data = div.attr('data');
        div.jsonView(data, {collapsed: true});
    });
});

t2hui.sleep = function(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

t2hui.fetch = function(url, cb, spin_in) {
    var last_index = 0;
    var running = false;
    var done = false;

    if (spin_in) {
        spin_in.addClass('spinner');
    }

    $.ajax(url + '?content-type=application/x-jsonl', {
        async: true,
        complete: function() {
            done = true;

            if (spin_in && !running) {
                spin_in.removeClass('spinner');
            }

            return true;
        },
        xhrFields: {
            onprogress: async function(e) {
                if (running) return;
                running = true;

                while(true) {
                    var todo = e.currentTarget.response;
                    var start = last_index;
                    last_index = todo.lastIndexOf("\n");

                    var now = todo.substring(start, last_index);
                    var items = now.split("\n");
                    var len = items.length;

                    var counter = 0;
                    for (var i = 0; i < len; i++) {
                        var json = items[i];
                        if (!json) { continue }

                        counter++;
                        var item = JSON.parse(json);
                        cb(item);

                        if (!(counter % 25)) {
                            await t2hui.sleep(50);
                        }
                    };

                    if (!counter) break;
                }

                running = false;

                if (done && spin_in) {
                    spin_in.removeClass('spinner');
                }
            }
        }
    });
};

t2hui.apply_expander = function(exp, cb) {
    var head = exp.children('div.expander-head').first();
    var body = exp.children('div.expander-body').first();

    head.addClass('closed');
    body.addClass('closed');

    head.click(function() {
        body.slideToggle();

        head.toggleClass('open');
        head.toggleClass('closed');

        body.toggleClass('open');
        body.toggleClass('closed');
    });

    if (cb) {
        head.one('click', cb);
    }
};

t2hui.build_expander = function(title, add_class, cb) {
    var root = $('<div class="expander"></div>');
    var head = $('<div class="expander-head"><div class="expander-title">' + title + '</div></div>');
    var body = $('<div class="expander-body"></div>');

    if (add_class) {
        root.addClass(add_class);
    }

    root.append(head);
    root.append(body);
    t2hui.apply_expander(root, cb);

    return { "root": root, "head": head, "body": body };
}
