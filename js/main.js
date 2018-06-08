$( function() {
    $( '.nav' ).each( function() {
        var item = $(this)
        setNav(item, item.attr( 'id' ));
    });

    var hash = window.location.hash
    if ( hash ) {
        var page = hash.split('-');
        $( page[0] ).trigger( 'click' )
    }
    else {
        $( '#introduction' ).trigger( 'click' )
    }

    var navstate = 1;
    $('#nonav').click( function() {
        if ( navstate ) {
            navstate = 0;
            $('#view').addClass( 'nonav' );
            $('#subnav').addClass( 'nonav' );
            $('ul.second_subnav').addClass( 'nonav' );
            $(this).addClass( 'nonav' );
            $(this).text( '' );
        }
        else {
            navstate = 1;
            $('#view').removeClass( 'nonav' );
            $('#subnav').removeClass( 'nonav' );
            $('ul.second_subnav').removeClass( 'nonav' );
            $(this).removeClass( 'nonav' );
            $(this).text( 'Hide Navigation' );
        }
    });
})

function setNav(elem, id) {
    elem.click( function() {
        var item = $(this)

        $('#subnav ul').empty();
        $('ul.second_subnav').detach();
        $('#view').empty();
        $('#error_window').click( function() {
            $(this).hide();
        });

        jQuery.ajax(
            id + '.html',
            {
                dataType: 'html',
                success: function( data ) {
                    $( '.nav' ).removeClass( 'active' )
                    item.addClass( 'active' )

                    build_content( data );
                    fixView();
                },
                error: function() {
                    $( '#error_window' ).show();
                    $( '#error_window ul.errors' ).append( "<li>Error loading page</li>" )
                    $( '.nav' ).removeClass( 'active' )
                    item.addClass( 'active' )
                    fixView();
                }
            }
        )
    });
}

function fixView() {
    var height = $('#subnav').outerHeight();
    if ( height < 350 ) height = 350;
    $('#view').css( 'min-height', height );
}

function build_content( data ) {
    var view = $( '#view' );
    var subnav = $( 'ul#main_subnav' );

    var hash = window.location.hash;
    if ( !hash ) hash = '#introduction';
    var nav = hash.split('-');

    var new_stuff = $( '<div></div>' );
    new_stuff.html( data );
    $(new_stuff).find( 'dl.listnav' ).each( function() {
        $(this).children('dt').each( function() {
            var id = $(this).attr( 'id' );
            var dt = $(this);
            var dd = $(this).next();
            var navitem = $(
                '<li id="' + id + '"><a href="' + nav[0] + '-' + id + '">' + dt.html() + '</a></li>'
            );
            var classes = dd.attr( 'class' );
            var viewitem = $(
                '<div style="display: none" class="' + classes + '">' + dd.html() + '</div>'
            );

            process( id, viewitem );

            var normal_click = function() {
                view.children().hide();
                $('ul.second_subnav').hide();
                subnav.children().removeClass( 'active' );
                viewitem.show();
                var sn = $('ul#SN-' + id);
                if ( sn.length ) {
                    sn.show();
                    sn.children().removeClass('active');
                    //if ( sn.children().length > 4 ) {
                    //    subnav.children().hide();
                    //    navitem.unbind( 'click' );
                    //    navitem.click( function() {
                    //        subnav.children().show();
                    //        navitem.unbind( 'click' );
                    //        navitem.click( normal_click );
                    //        fixView();
                    //    });
                    //}
                    sn.children().first().click();
                }
                navitem.addClass( 'active' );
                navitem.show();
                fixView();
            };

            navitem.click( normal_click );

            subnav.append( navitem );
            view.append( viewitem );
        });

        if ( nav[1] ) {
            $( '#' + nav[1] ).trigger( 'click' );
            $('ul#SN-' + nav[1]).each( function() {
                $(this).show();
                if ( nav[2] ) {
                    $(this).find( '#' + nav[2] ).trigger( 'click' );
                }
            });
        }
        else {
            subnav.children().first().trigger( 'click' );
        }
    })
}

function process( id, container ) {
    container.find( 'div.symbol_list' ).each( function() {
        var list = $(this);
        jQuery.ajax(
            list.attr( 'src' ),
            {
                dataType: 'json',
                success: function( data ) {
                    list.replaceWith( build_symbol_list( data ));
                    fixView();
                },
                error: function(blah, message1, message2) {
                    $( '#error_window' ).show();
                    $( '#error_window ul.errors' ).append( "<li>Error loading " + list.attr( 'src' ) + "</li>" )
                    fixView();
                }
            }
        )
    });

    container.find( 'dl.sub_list' ).each( function() {
        $(this).detach();
        build_sub_list( id, $(this) );
        fixView();
    });

    process_samples( container );
}

function process_samples( container ) {
    container.find( 'script.code' ).each( function() {
        $(this).replaceWith( build_code( $(this).text() ));
    });

    container.find( 'script.code_js' ).each( function() {
        $(this).replaceWith( build_js( $(this).text() ));
    });

    container.find( 'script.output' ).each( function() {
        $(this).replaceWith( build_output( $(this).text() ));
    });

    container.find( 'div.code' ).each( function() {
        var list = $(this);
        jQuery.ajax(
            list.attr( 'src' ),
            {
                dataType: 'text',
                success: function( data ) {
                    list.replaceWith( build_code( data ));
                    fixView();
                    start_debugger();
                },
                error: function(blah, message1, message2) {
                    $( '#error_window' ).show();
                    $( '#error_window ul.errors' ).append( "<li>Error loading " + list.attr( 'src' ) + "</li>" )
                    fixView();
                }
            }
        )
    });

    container.find( 'div.code_js' ).each( function() {
        var list = $(this);
        jQuery.ajax(
            list.attr( 'src' ),
            {
                dataType: 'text',
                success: function( data ) {
                    list.replaceWith( build_js( data ));
                    fixView();
                    start_debugger();
                },
                error: function(blah, message1, message2) {
                    $( '#error_window' ).show();
                    $( '#error_window ul.errors' ).append( "<li>Error loading " + list.attr( 'src' ) + "</li>" )
                    fixView();
                }
            }
        )
    });


    container.find( 'div.output' ).each( function() {
        var list = $(this);
        jQuery.ajax(
            list.attr( 'src' ),
            {
                dataType: 'text',
                success: function( data ) {
                    list.replaceWith( build_output( data ));
                    fixView();
                    start_debugger();
                },
                error: function(blah, message1, message2) {
                    $( '#error_window' ).show();
                    $( '#error_window ul.errors' ).append( "<li>Error loading " + list.attr( 'src' ) + "</li>" )
                    fixView();
                }
            }
        )
    });

    container.find( 'div.vim' ).each( function() {
        var list = $(this);
        jQuery.ajax(
            list.attr( 'src' ),
            {
                dataType: 'text',
                success: function( data ) {
                    list.replaceWith( build_vim( data ));
                    fixView();
                    start_debugger();
                },
                error: function(blah, message1, message2) {
                    $( '#error_window' ).show();
                    $( '#error_window ul.errors' ).append( "<li>Error loading " + list.attr( 'src' ) + "</li>" )
                    fixView();
                }
            }
        )
    });
}

function build_code( data ) {
    var brush = new SyntaxHighlighter.brushes.Perl();

    brush.init({ toolbar: false });
    return brush.getHtml( data );
}

function build_js( data ) {
    var brush = new SyntaxHighlighter.brushes.JScript();

    brush.init({ toolbar: false });
    return brush.getHtml( data );
}


function build_output( data ) {
    var brush = new SyntaxHighlighter.brushes.TAP();

    brush.init({ toolbar: false });
    return brush.getHtml( data );
}

function build_vim( data ) {
    var brush = new SyntaxHighlighter.brushes.Vimscript();

    brush.init({ toolbar: false });
    return brush.getHtml( data );
}


function build_sub_list( pid, list ) {
    var subnav = $( '<ul id="SN-' + pid + '" style="display: none;" class="second_subnav listnav"></ul>' );

    var hash = window.location.hash;
    if ( !hash ) hash = '#introduction';
    var nav = hash.split('-');

    list.children( 'dt' ).each( function() {
        var navkey = $(this).text();
        var section = $(this).next();
        process_samples( section );
        build_sub_list_item( pid, navkey, section, nav, subnav );
    });

    $("#subnav").append( subnav );
}

function build_sub_list_item( pid, navkey, section, nav, subnav ) {
    var navitem = $(
        '<li id="' + navkey + '"><a href="' + nav[0] + '-' + pid + '-' + navkey + '">' + navkey + '</a></li>'
    );
    var viewitem = $(
        '<div style="display: none"></div>'
    );
    viewitem.append( section );

    navitem.click( function() {
        $('#view').children().hide();
        subnav.children().removeClass( 'active' );
        navitem.addClass( 'active' );
        viewitem.show();
        fixView();
    });

    subnav.append( navitem );
    $('#view').append( viewitem );
}

function build_symbol_list( data ) {
    var table = $( '<table class="symbol_list"><tbody><tr><th>Name</th><th>Description &nbsp;&nbsp; <small>(Click a row for usage details)</small</th></tr></tbody></table>' );
    for (key in data) {
        var name = data[key]['name'];
        if ( !name ) name = key;
        var row = $( '<tr class="symbol" onclick="expandDesc(this)"></tr>' );
        row.append( $('<td class="left">' + name + '</td>') );
        row.append( $('<td class="right">' + data[key]['desc'] + '</td>') );

        var details = $( '<td colspan="2"></td>' );
        if ( data[key]['usage'] ) {
            var list = $( '<ul class="usage"></ul>' );
            for ( i in data[key]['usage'] ) {
                var item = $( '<li>' + data[key]['usage'][i] + '</li>' );
                list.append( item );
            }
            details.append( list );
        }
        details.append( data[key]['details'] );

        var drow = $( '<tr class="symbol_details" style="display: none;"></tr>' );
        drow.append( details );

        table.append( row );
        table.append( drow );
    }

    return table;
}

function expandDesc( e ) {
    $(e).toggleClass( 'open' );
    $(e).next().toggle();
}

function openRole( role ) {
    $('#main_subnav').find('#roles').trigger( 'click' );
    $('#SN-roles').find('#' + role).trigger( 'click' );
    fixView();
}
