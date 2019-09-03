var t2hui = {};

$(function() {
    t2hui.dynstyle = $('style#dynamic-style')[0].sheet;

    $("div.expander").each(function() { t2hui.apply_expander($(this)) });

    $("div.json-view").each(function() {
        var div = $(this);
        var data = div.attr('data');
        div.jsonView(data, {collapsed: true});
    });

    var modal = $("div#free_modal");
    var modal_body = $("div#modal_body");
    $("div#free_modal").click(function()  { modal.slideUp(function() { modal_body.empty() })});
    $("div#modal_close").click(function() { modal.slideUp(function() { modal_body.empty() })});
    $("div#modal_inner_wrap").click(function(e) { e.stopPropagation() });
});

t2hui.added_styles = {};
t2hui.add_style = function(text) {
    if (t2hui.added_styles[text]) { return; }
    t2hui.added_styles[text] = true;
    t2hui.dynstyle.insertRule(text);
}

t2hui.sleep = function(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

t2hui.fetch = function(url, args, cb) {
    if (!args) { args = {} }

    var prog = $('<span>|</span>');
    $('div#progress_bar').append(prog);

    var last_index = 0;
    var running = false;
    var done = false;
    var iterate = async function(response) {
        if (running) return;
        running = true;

        while(true) {
            var start = last_index;
            last_index = response.lastIndexOf("\n");

            var now = response.substring(start, last_index);
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
    };


    $.ajax(url + '?content-type=application/x-jsonl', {
        async: true,
        data: args.data,
        xhrFields: {
            onprogress: async function(e) {
                if (!e || !e.currentTarget) return;
                iterate(e.currentTarget.response);
            }
        },
        success: async function(response) {
            while (running) { await t2hui.sleep(50); }
            iterate(response);
            prog.detach();
        },
        complete: async function() {
            while (running) { await t2hui.sleep(50); }

            if (args.done) { args.done() }

            prog.detach();
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

t2hui.sanitize_class = function(text) {
    return text.replace(/ /g, '-').replace(/!/g, 'N');
}

t2hui.build_tooltip = function(box, text) {
    var ddd = $('<span class="tooltip-expand"><img src="/img/dotdotdot.png" /></span');

    var tooltip;
    var locked = false;
    ddd.hover(
        function() {
            if (!tooltip) {
                locked = false;
                tooltip = $('<div class="tooltip">' + text + '</div>');
                ddd.after(tooltip)
                tooltip.hover(function() { box.removeClass('hover') });
            }
            box.removeClass('hover');
        },
        function() {
            if (tooltip && !locked) { tooltip.detach(); tooltip = null }
        }
    );

    ddd.click(function() {
        locked = !locked;
        if (tooltip && !locked) {
            tooltip.detach();
            tooltip = null;
            ddd.removeClass('locked');
        }
        else {
            ddd.addClass('locked');
        }
    });

    return ddd;
};
