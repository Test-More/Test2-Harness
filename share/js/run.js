$(function() {
    $("div.run").each(function() {
        var me = $(this);
        t2hui.build_run(me.attr('data-run-id'), me);
    });
});

t2hui.build_run = function(run_id, root, list) {
    if (root === null || root === undefined) {
        root = $('<div class="run" data-run-id="' + run_id + '"></div>');
    }

    var run_uri = base_uri + 'run/' + run_id;
    var jobs_uri = run_uri + '/jobs';

    $.ajax(run_uri, {
        'data': { 'content-type': 'application/json' },
        'success': function(item) {
            var dash = t2hui.build_dashboard_runs([item]);
            root.prepend($('<h3>Run: ' + run_id + '</h3>'), dash, $('<hr />'));

        },
    });

    var wrapper = $('<div class="job_list_wrapper"></div>');
    var jobs = $('<table class="job_list"></table>');
    wrapper.append(jobs);
    jobs.append('<tr><th>Tools</th><th>P</th><th>F</th><th>File/Job Name</th><th>Exit</th><tr>)');


    var pos  = $('<tr style="display: none;"></tr>');
    var log = pos.clone();
    var error = pos.clone();
    var other = pos.clone();
    jobs.append(log, error, other);

    root.append('<h3>Jobs:</h3>', wrapper);

    var inject = function(job) {
        if (job === null || job === undefined) {
            job = this;
        }

        job_dom = t2hui.build_run_job(job);

        if (!job.short_file) {
            log.before(job_dom);
        }
        else if (job.fail) {
            error.before(job_dom);
        }
        else {
            other.before(job_dom);
        }
    }

    if (list === null || list === undefined) {
        t2hui.fetch(jobs_uri, {}, inject);
    }
    else {
        $(list).each(inject);
    };

    return root;
};


t2hui.build_run_job = function(job) {
    var tools = $('<td class="tools"></td>');

    var params = $('<div class="tool etoggle" title="See Job Parameters"><i class="far fa-list-alt"></i></div>');
    tools.append(params);
    params.click(function() {

        $('#modal_body').empty();
        $('#modal_body').text("loading...");
        $('#free_modal').slideDown();

        var job_uri = base_uri + 'job/' + job.job_id;

        $.ajax(job_uri, {
            'data': { 'content-type': 'application/json' },
            'success': function(job) {
                $('#modal_body').empty();
                $('#modal_body').jsonView(job.parameters, {collapsed: true});
            },
        });
    });

    var link = base_uri + 'job/' + job.job_id;
    var go = $('<a class="tool etoggle" title="Open Job" href="' + link + '"><i class="fas fa-external-link-alt"></i></a>');
    tools.append(go);

    var me = [
        tools[0],
        $('<td class="pass count">' + (job.pass_count || '0') + '</td>')[0],
        $('<td class="fail count">' + (job.fail_count || '0') + '</td>')[0],
        $('<td class="job_name">' + (job.short_file || job.name) + '</td>')[0],
        $('<td class="exit count">' + (job.exit != null ? job.exit : 'N/A') + '</td>')[0],
    ];

    var $me = $('<tr></tr>').append($(me));

    if (job.short_file) {
        if (job.fail) {
            $me.addClass('error_set');
        }
        else {
            $me.addClass('success_set');
        }
    }

    return $me;
};
