#!/usr/bin/env nextflow
nextflow.enable.dsl = 2

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT PARAMETER-SPECIFIED ALTERNATIVE MODULES (INCLUDES LOCAL AND NF-CORE-MODIFIED)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
// TODO: Build into subworkflows
ch_aligner = params.aligner
ch_msa_trimmer = params.msa_trimmer
ch_tree_method = params.tree_method
if (ch_aligner == "witch") {
    include { WITCH as ALIGN_SEQS                   } from '../noveltree/modules/local/witch'
    include { WITCH as ALIGN_REMAINING_SEQS         } from '../noveltree/modules/local/witch'
} else {
    include { MAFFT as ALIGN_SEQS                   } from '../noveltree/modules/nf-core-modified/mafft'
    include { MAFFT as ALIGN_REMAINING_SEQS         } from '../noveltree/modules/nf-core-modified/mafft'
}
if (ch_msa_trimmer == "clipkit") {
    include { CLIPKIT as TRIM_MSAS                  } from '../noveltree/modules/local/clipkit'
    include { CLIPKIT as TRIM_REMAINING_MSAS        } from '../noveltree/modules/local/clipkit'
} else if (ch_msa_trimmer == 'cialign') {
    include { CIALIGN as TRIM_MSAS                  } from '../noveltree/modules/local/cialign'
    include { CIALIGN as TRIM_REMAINING_MSAS        } from '../noveltree/modules/local/cialign'
}
if (ch_tree_method == "iqtree") {
    include { IQTREE as INFER_TREES                 } from '../noveltree/modules/nf-core-modified/iqtree'
    include { IQTREE as INFER_REMAINING_TREES       } from '../noveltree/modules/nf-core-modified/iqtree'
} else {
    include { FASTTREE as INFER_TREES               } from '../noveltree/modules/local/fasttree'
    include { FASTTREE as INFER_REMAINING_TREES     } from '../noveltree/modules/local/fasttree'
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOW
//
include { INPUT_CHECK                               } from '../noveltree/subworkflows/local/input_check'

//
// MODULE
//
// Modules being run twice (for MCL testing and full analysis)
// needs to be included twice under different names.
include { ORTHOFINDER_PREP as ORTHOFINDER_PREP_ALL  } from '../noveltree/modules/local/orthofinder_prep'
include { ORTHOFINDER_PREP as ORTHOFINDER_PREP_TEST } from '../noveltree/modules/local/orthofinder_prep'
include { ORTHOFINDER_MCL as ORTHOFINDER_MCL_TEST   } from '../noveltree/modules/local/orthofinder_mcl'
include { ORTHOFINDER_MCL as ORTHOFINDER_MCL_ALL    } from '../noveltree/modules/local/orthofinder_mcl'
include { ANNOTATE_UNIPROT                          } from '../noveltree/modules/local/annotate_uniprot'
include { COGEQC                                    } from '../noveltree/modules/local/cogeqc'
include { SELECT_INFLATION                          } from '../noveltree/modules/local/select_inflation'
include { FILTER_ORTHOGROUPS                        } from '../noveltree/modules/local/filter_orthogroups'
include { ASTEROID                                  } from '../noveltree/modules/local/asteroid'
include { SPECIESRAX                                } from '../noveltree/modules/local/speciesrax'
include { GENERAX_PER_FAMILY                        } from '../noveltree/modules/local/generax_per_family'
include { GENERAX_PER_SPECIES                       } from '../noveltree/modules/local/generax_per_species'
include { ORTHOFINDER_PHYLOHOGS                     } from '../noveltree/modules/local/orthofinder_phylohogs'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE-MODIFIED MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE
//
// Modules being run twice (for MCL testing and full analysis)
// needs to be included twice under different names.
include { BUSCO as BUSCO_SHALLOW                    } from '../noveltree/modules/nf-core-modified/busco'
include { BUSCO as BUSCO_BROAD                      } from '../noveltree/modules/nf-core-modified/busco'
include { DIAMOND_BLASTP as DIAMOND_BLASTP_ALL      } from '../noveltree/modules/nf-core-modified/diamond_blastp'
include { DIAMOND_BLASTP as DIAMOND_BLASTP_TEST     } from '../noveltree/modules/nf-core-modified/diamond_blastp'
include { IQTREE_PMSF as IQTREE_PMSF_ALL            } from '../noveltree/modules/nf-core-modified/iqtree_pmsf'
include { IQTREE_PMSF as IQTREE_PMSF_REMAINING      } from '../noveltree/modules/nf-core-modified/iqtree_pmsf'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Define a function to instantiate a meta.map to correspond gene family names
// with all outputs we'll be producing
// Function to get list of [meta, [file]]
def create_og_channel(Object inputs) {
    // If the input is a string, convert it to a list containing a single element
    if (inputs instanceof String) {
        inputs = [inputs]
    }
    // create list of maps
    def metaList = []
    inputs.each { input ->
        def meta = [:]
        meta.og = input
        metaList.add(meta)
    }
    return metaList
}



//
// WORKFLOW: Run main Arcadia-Science/noveltree analysis pipeline
//
workflow INIT_ORTHO_ORTHOFINDER {
    take:
    samplesheet
    search_params
    outdir
    mcl_inflation
    prefilter_proteomes_domfastas

    main:

    ch_versions = Channel.empty()
    ch_best_inflation = Channel.of(params.mcl_inflation)

    // Determine which input to use based on prefilter_proteomes_domfastas
    prefilter_proteomes_domfastas.view { it -> "prefilter_proteomes_domfastas: $it" }

    ch_all_data = prefilter_proteomes_domfastas
        .ifEmpty { 
            Channel
                .fromPath(samplesheet)
                .splitCsv(header:true)
                .map { row -> tuple([id: row.id], file(row.fasta)) }
        }
    ch_all_data.view { it -> "ch_all_data: $it" }

    species_name_list = ch_all_data.collect { it[0].id }
    complete_prots_list = ch_all_data.collect { it[1] }

    //
    // MODULE: Prepare directory structure and fasta files according to
    //         OrthoFinder's preferred format for downstream MCL clustering
    //
    ORTHOFINDER_PREP_ALL(complete_prots_list, "complete_dataset")
    ch_versions = ch_versions.mix(ORTHOFINDER_PREP_ALL.out.versions)

    //
    // MODULE: All-v-All diamond/blastp
    //
    // For the full dataset, to be clustered into orthogroups using
    // the best inflation parameter.
    DIAMOND_BLASTP_ALL(
        ch_all_data,
        ORTHOFINDER_PREP_ALL.out.fastas.flatten(),
        ORTHOFINDER_PREP_ALL.out.diamonds.flatten(),
        "txt",
        "false"
    )
    ch_versions = ch_versions.mix(DIAMOND_BLASTP_ALL.out.versions)

    // Using this best-performing inflation parameter, infer orthogroups for
    // all samples.
    ORTHOFINDER_MCL_ALL(
        ch_best_inflation,
        DIAMOND_BLASTP_ALL.out.txt.collect(),
        ORTHOFINDER_PREP_ALL.out.fastas,
        ORTHOFINDER_PREP_ALL.out.diamonds,
        ORTHOFINDER_PREP_ALL.out.sppIDs,
        ORTHOFINDER_PREP_ALL.out.seqIDs,
        "complete_dataset"
    )
}

workflow NOT_READY {
    //
    // MODULE: FILTER_ORTHOGROUPS
    // Subset orthogroups based on their copy number and distribution
    // across species and taxonomic group.
    // The conservative subset will be used for species tree inference,
    // and the remainder will be used to infer gene family trees only.
    FILTER_ORTHOGROUPS(
        INPUT_CHECK.out.complete_samplesheet,
        ORTHOFINDER_MCL_ALL.out.inflation_dir,
        params.min_num_seq_per_og,
        params.min_num_spp_per_og,
        params.min_prop_spp_for_spptree,
        params.min_num_grp_per_og,
        params.max_copy_num_spp_tree,
        params.max_copy_num_gene_trees
    )

    // Create meta maps for the two sets by just providing the simple name of each orthogroup:
    spptree_og_names = FILTER_ORTHOGROUPS.out.spptree_fas.map { file -> file.simpleName }
    spptree_og_map = spptree_og_names.map { create_og_channel(it) }.flatten()
    genetree_og_names = FILTER_ORTHOGROUPS.out.genetree_fas.map { file -> file.simpleName }
    genetree_og_map = genetree_og_names.map { create_og_channel(it) }.flatten()

    // And now create the tuple of these output fastas paired with the meta map
    ch_spptree_fas = spptree_og_map.merge(FILTER_ORTHOGROUPS.out.spptree_fas.flatten())
    ch_genetree_fas = genetree_og_map.merge(FILTER_ORTHOGROUPS.out.genetree_fas.flatten())

    //
    // MODULE: ALIGN_SEQS
    // Infer multiple sequence alignments of orthogroups/gene
    // families using WITCH (default) or MAFFT
    //
    // For the extreme core set to be used in species tree inference
    if (ch_aligner == "witch") {
        ALIGN_SEQS(ch_spptree_fas)
        ch_versions = ch_versions.mix(ALIGN_SEQS.out.versions)
    } else {
        ALIGN_SEQS(ch_spptree_fas)
        ch_versions = ch_versions.mix(ALIGN_SEQS.out.versions)
    }

    // And for the remaining orthogroups:
    // Only start once species tree MSAs have finished (to give them priority)
    // We use the combination of collect().count() to hold off on running this
    // set of MSAs, while avoiding unnecessarily staging thousands of large files.
    if (ch_aligner == "witch") {
        ALIGN_REMAINING_SEQS(ch_genetree_fas)
    } else {
        ALIGN_REMAINING_SEQS(ch_genetree_fas)
    }

    //
    // MODULE: TRIM_MSAS
    // Trim gappy regions, poorly aligned, or and phylogenetically
    // uninformative/problematic sites from the MSAs using either
    // CIAlign or ClipKIT based on parameter specification.
    //
    if (ch_msa_trimmer == 'none') {
        if (ch_aligner == 'witch') {
            ch_core_og_maplinks = ALIGN_SEQS.out.map_link
            ch_rem_og_maplinks = ALIGN_REMAINING_SEQS.out.map_link
            ch_core_og_clean_msas = ALIGN_SEQS.out.cleaned_msas
            ch_rem_og_clean_msas = ALIGN_REMAINING_SEQS.out.cleaned_msas
        } else {
            ch_core_og_maplinks = ALIGN_SEQS.out.map_link
            ch_rem_og_maplinks = ALIGN_REMAINING_SEQS.out.map_link
            ch_core_og_clean_msas = ALIGN_SEQS.out.msas
            ch_rem_og_clean_msas = ALIGN_REMAINING_SEQS.out.msas
        }
    } else {
        if (ch_aligner == 'witch') {
            TRIM_MSAS(ALIGN_SEQS.out.cleaned_msas)
            TRIM_REMAINING_MSAS(ALIGN_REMAINING_SEQS.out.cleaned_msas)
            ch_core_og_maplinks = TRIM_MSAS.out.map_link
            ch_rem_og_maplinks = TRIM_REMAINING_MSAS.out.map_link
            ch_core_og_clean_msas = TRIM_MSAS.out.cleaned_msas
            ch_rem_og_clean_msas = TRIM_REMAINING_MSAS.out.cleaned_msas
            ch_versions = ch_versions.mix(TRIM_MSAS.out.versions)
        } else {
            TRIM_MSAS(ALIGN_SEQS.out.msas)
            TRIM_REMAINING_MSAS(ALIGN_REMAINING_SEQS.out.msas)
            ch_core_og_maplinks = TRIM_MSAS.out.map_link
            ch_rem_og_maplinks = TRIM_REMAINING_MSAS.out.map_link
            ch_core_og_clean_msas = TRIM_MSAS.out.cleaned_msas
            ch_rem_og_clean_msas = TRIM_REMAINING_MSAS.out.cleaned_msas
            ch_versions = ch_versions.mix(TRIM_MSAS.out.versions)
        }
    }
    // Create channels that are just lists of all the msas, and protein-species
    // map links that are provided in bulk to SpeciesRax
    core_og_maplink_list = ch_core_og_maplinks.collect { it[1] }
    core_og_clean_msa_list = ch_core_og_clean_msas.collect { it[1] }

    //
    // MODULE: INFER_TREES
    // Infer gene-family trees from the trimmed MSAs using either
    // VeryFastTree or IQ-TREE.
    //
    INFER_TREES(ch_core_og_clean_msas, params.tree_model)
    INFER_REMAINING_TREES(ch_rem_og_clean_msas, params.tree_model)
    ch_versions = ch_versions.mix(INFER_TREES.out.versions)

    // Run IQ-TREE PMSF if model is specified, and subsequently collect final
    // phylogenies into a channel for downstram use
    if (params.tree_model_pmsf != 'none') {
        //
        // MODULE: IQTREE_PMSF
        // Infer gene-family trees from the trimmed MSAs and guide trees from the
        // previous tree inference module
        //
        // Be sure that both the MSAs and guide trees are sorted into the same
        // order as before to prevent any hiccups - do so by temporarily
        // joining the two channels.
        ch_pmsf_input = ch_core_og_clean_msas.join(INFER_TREES.out.phylogeny)
        ch_pmsf_input_remaining = ch_rem_og_clean_msas.join(INFER_REMAINING_TREES.out.phylogeny)
        // Now run
        IQTREE_PMSF(ch_pmsf_input, params.tree_model_pmsf)
        IQTREE_PMSF_REMAINING(ch_pmsf_input_remaining, params.tree_model_pmsf)
        ch_versions = ch_versions.mix(IQTREE_PMSF.out.versions)

        ch_core_gene_trees = IQTREE_PMSF.out.phylogeny
        ch_rem_gene_trees = IQTREE_PMSF_REMAINING.out.phylogeny
        // And create a channel/list (no tuple) of just the core trees used by Asteroid
        core_gene_tree_list = ch_core_gene_trees.collect { it[1] }
    } else {
        ch_core_gene_trees = INFER_TREES.out.phylogeny
        ch_rem_gene_trees = INFER_REMAINING_TREES.out.phylogeny
        core_gene_tree_list = ch_core_gene_trees.collect { it[1] }
    }

    // The following two steps will just be done for the core set of
    // orthogroups that will be used to infer the species tree
    //
    // MODULE: ASTEROID
    // Alrighty, now let's infer an intial, unrooted species tree using Asteroid
    //
    ASTEROID(species_name_list, core_gene_tree_list, params.outgroups)
        .rooted_spp_tree
        .set { ch_asteroid }
    ch_versions = ch_versions.mix(ASTEROID.out.versions)

    // If no outgroups are provided (and thus no rooted species tree output
    // by Asteroid), define ch_asteroid as a null/empty channel
    if (params.outgroups == "none") {
        ch_asteroid = Channel.value("none")
    }

    //
    // MODULE: SPECIESRAX
    // Now infer the rooted species tree with SpeciesRax,
    // reconcile gene family trees, and infer per-family
    // rates of gene-family duplication, transfer, and loss
    //
    SPECIESRAX(core_og_maplink_list, core_gene_tree_list, core_og_clean_msa_list, ch_asteroid)
        .speciesrax_tree
        .set { ch_speciesrax }
    ch_versions = ch_versions.mix(SPECIESRAX.out.versions)

    // Now prepare for analysis with GeneRax
    ch_all_map_links = ch_core_og_maplinks
        .concat(ch_rem_og_maplinks)
    ch_all_gene_trees = ch_core_gene_trees
        .concat(ch_rem_gene_trees)
    ch_all_og_clean_msas = ch_core_og_clean_msas
        .concat(ch_rem_og_clean_msas)

    // Join these so that each gene family may be dealt with asynchronously as soon
    // as possible, and include with them the species tree.
    ch_generax_input = ch_all_map_links
        .join(ch_all_gene_trees)
        .join(ch_all_og_clean_msas)
        .combine(ch_speciesrax)

    GENERAX_PER_FAMILY(
        ch_generax_input
    )
        .generax_per_fam_gfts
        .collect { it[1] }
        .set { ch_recon_perfam_gene_trees }

    GENERAX_PER_SPECIES(
        ch_generax_input
    )
        .generax_per_spp_gfts
        .collect { it[1] }
        .set { ch_recon_perspp_gene_trees }

    //
    // MODULE: ORTHOFINDER_PHYLOHOGS
    // Now using the reconciled gene family trees and rooted species tree,
    // parse orthogroups/gene families into hierarchical orthogroups (HOGs)
    // to identify orthologs and output orthogroup-level summary stats.
    //
    ORTHOFINDER_PHYLOHOGS(
        ch_speciesrax,
        ORTHOFINDER_MCL_ALL.out.inflation_dir,
        ORTHOFINDER_PREP_ALL.out.fastas,
        ORTHOFINDER_PREP_ALL.out.sppIDs,
        ORTHOFINDER_PREP_ALL.out.seqIDs,
        ch_recon_perspp_gene_trees,
        DIAMOND_BLASTP_ALL.out.txt.collect()
    )
}

